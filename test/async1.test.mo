import Principal "mo:base/Principal";
import { print } "mo:base/Debug";

import TokenHandler "../src";
import MockLedger "mock_ledger";
import TestJournal "test_journal";

type TestLedgerAPI = TokenHandler.LedgerAPI and { mock : MockLedger.MockLedger };

let mock_ledger : MockLedger.MockLedger = await MockLedger.MockLedger();

let ledger : TestLedgerAPI = {
  fee = mock_ledger.icrc1_fee;
  balance_of = mock_ledger.icrc1_balance_of;
  transfer = mock_ledger.icrc1_transfer;
  transfer_from = mock_ledger.icrc2_transfer_from;
  mock = mock_ledger; // mock ledger for controlling responses
};

let anon_p = Principal.fromBlob("");
let user1 = Principal.fromBlob("1");
let user2 = Principal.fromBlob("2");
let account = { owner = Principal.fromBlob("o"); subaccount = null };
let user1_account = { owner = user1; subaccount = null };
let user2_account = { owner = user2; subaccount = null };

func state(handler : TokenHandler.TokenHandler) : (Nat, Nat, Nat) {
  let s = handler.state();
  (
    s.balance.deposited,
    s.balance.consolidated,
    s.users.queued,
  );
};

func createHandler(triggerOnNotifications : Bool) : (TokenHandler.TokenHandler, TestJournal.TestJournal) {
  TestJournal.TestJournal()
  |> (
    TokenHandler.TokenHandler({
      ledgerApi = ledger;
      ownPrincipal = anon_p;
      initialFee = 0;
      triggerOnNotifications;
      log = _.log;
    }),
    _,
  );
};

module Debug {
  public func state(handler : TokenHandler.TokenHandler) {
    print(
      debug_show handler.state()
    );
  };
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // init state
  assert handler.ledgerFee() == 0;
  assert journal.hasEvents([]);

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // notify with 0 balance
  await ledger.mock.set_balance(0);
  assert (await* handler.notify(user1)) == ?(0, 0);
  assert state(handler) == (0, 0, 0);
  assert journal.hasEvents([]);

  // notify with balance <= fee
  await ledger.mock.set_balance(5);
  assert (await* handler.notify(user1)) == ?(0, 0);
  assert state(handler) == (0, 0, 0);
  assert journal.hasEvents([]);

  // notify with balance > fee
  await ledger.mock.set_balance(6);
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state(handler) == (6, 0, 1);
  assert journal.hasEvents([#issued(1), #newDeposit(6)]);

  // increase fee while item still in queue (trigger did not run yet)
  await ledger.mock.set_fee(6);
  ignore await* handler.fetchFee();
  assert state(handler) == (0, 0, 0); // recalculation after fee update
  assert journal.hasEvents([
    #issued(-1),
    #feeUpdated({ new = 6; old = 5 }),
    #depositMinimumUpdated({ new = 7; old = 6 }),
    #withdrawalMinimumUpdated({ new = 7; old = 6 }),
    #depositFeeUpdated({ new = 6; old = 5 }),
    #withdrawalFeeUpdated({ new = 6; old = 5 }),
  ]);

  // increase deposit again
  await ledger.mock.set_balance(7);
  assert (await* handler.notify(user1)) == ?(7, 1);
  assert state(handler) == (7, 0, 1);
  assert journal.hasEvents([
    #issued(1),
    #newDeposit(7),
  ]);

  // increase fee while notify is underway (and item still in queue)
  // scenario 1: old_fee < previous = latest <= new_fee
  // this means no new deposit has happened (latest = previous)
  await ledger.mock.lock_balance("INCREASE_FEE_WHILE_NOTIFY_IS_UNDERWAY_SCENARIO_1");
  let f1 = async { await* handler.notify(user1) };
  await ledger.mock.set_fee(10); // fee 6 -> 10
  assert state(handler) == (7, 0, 1); // state from before
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #issued(-1),
    #feeUpdated({ new = 10; old = 6 }),
    #depositMinimumUpdated({ new = 11; old = 7 }),
    #withdrawalMinimumUpdated({ new = 11; old = 7 }),
    #depositFeeUpdated({ new = 10; old = 6 }),
    #withdrawalFeeUpdated({ new = 10; old = 6 }),
  ]);
  assert state(handler) == (0, 0, 0); // state changed
  await ledger.mock.release_balance(); // let notify return
  assert (await f1) == ?(0, 0); // deposit <= new fee
  assert journal.hasEvents([]);

  // increase deposit again
  await ledger.mock.set_balance(15);
  assert (await* handler.notify(user1)) == ?(15, 5);
  assert state(handler) == (15, 0, 1);
  assert journal.hasEvents([
    #issued(5),
    #newDeposit(15),
  ]);

  // increase fee while notify is underway (and item still in queue)
  // scenario 2: old_fee < previous <= new_fee < latest
  await ledger.mock.set_balance(20);
  await ledger.mock.lock_balance("INCREASE_FEE_WHILE_NOTIFY_IS_UNDERWAY_SCENARIO_2");
  let f2 = async { await* handler.notify(user1) }; // would return ?(5, _) at old fee
  await ledger.mock.set_fee(15); // fee 10 -> 15
  assert state(handler) == (15, 0, 1); // state from before
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #issued(-5),
    #feeUpdated({ new = 15; old = 10 }),
    #depositMinimumUpdated({ new = 16; old = 11 }),
    #withdrawalMinimumUpdated({ new = 16; old = 11 }),
    #depositFeeUpdated({ new = 15; old = 10 }),
    #withdrawalFeeUpdated({ new = 15; old = 10 }),
  ]);
  assert state(handler) == (0, 0, 0); // state changed
  await ledger.mock.release_balance(); // let notify return
  assert (await f2) == ?(20, 5); // credit = latest - new_fee
  assert state(handler) == (20, 0, 1); // state should have changed
  assert journal.hasEvents([
    #issued(5),
    #newDeposit(20),
  ]);

  // decrease fee while notify is underway (and item still in queue)
  // new_fee < old_fee < previous == latest
  await ledger.mock.lock_balance("DECREASE_FEE_WHILE_NOTIFY_IS_UNDERWAY");
  let f3 = async { await* handler.notify(user1) };
  await ledger.mock.set_fee(10); // fee 15 -> 10
  assert state(handler) == (20, 0, 1); // state from before
  ignore await* handler.fetchFee();

  assert journal.hasEvents([
    #issued(+5),
    #feeUpdated({ new = 10; old = 15 }),
    #depositMinimumUpdated({ new = 11; old = 16 }),
    #withdrawalMinimumUpdated({ new = 11; old = 16 }),
    #depositFeeUpdated({ new = 10; old = 15 }),
    #withdrawalFeeUpdated({ new = 10; old = 15 }),
  ]);
  assert state(handler) == (20, 0, 1); // state unchanged
  await ledger.mock.release_balance(); // let notify return
  assert (await f3) == ?(0, 0);
  assert handler.userCredit(user1) == 10; // credit increased
  assert state(handler) == (20, 0, 1); // state unchanged

  // call multiple notify() simultaneously
  // only the first should return state, the rest should not be executed
  await ledger.mock.lock_balance("CALL_MULTIPLE_NOTIFY_SIMULTANEOUSLY");
  let fut1 = async { await* handler.notify(user1) };
  let fut2 = async { await* handler.notify(user1) };
  let fut3 = async { await* handler.notify(user1) };
  assert (await fut2) == null; // should return null
  assert (await fut3) == null; // should return null
  await ledger.mock.release_balance(); // let notify return
  assert (await fut1) == ?(0, 0); // first notify() should return state
  assert handler.userCredit(user1) == 10; // credit unchanged
  assert state(handler) == (20, 0, 1); // state unchanged because deposit has not changed
  assert journal.hasEvents([]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  // Test credit inc from notify()

  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // notify 1
  await ledger.mock.set_balance(7);
  assert (await* handler.notify(user1)) == ?(7, 2);
  assert handler.userCredit(user1) == 2;
  assert state(handler) == (7, 0, 1);
  assert journal.hasEvents([
    #issued(2),
    #newDeposit(7),
  ]);

  // notify 2
  await ledger.mock.set_balance(17);
  assert (await* handler.notify(user1)) == ?(10, 10);
  assert handler.userCredit(user1) == 12;
  assert state(handler) == (17, 0, 1);
  assert journal.hasEvents([
    #issued(10),
    #newDeposit(10),
  ]);
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);
  // increase fee while deposit is being consolidated (implicitly)
  // scenario 1: old_fee < deposit <= new_fee
  // consolidation should fail and deposit should be reset
  await ledger.mock.set_balance(10);
  assert (await* handler.notify(user1)) == ?(10, 5);
  assert journal.hasEvents([
    #issued(5),
    #newDeposit(10),
  ]);
  assert state(handler) == (10, 0, 1);
  await ledger.mock.lock_transfer("IMP_INCREASE_FEE_WHILE_DEPOSIT_IS_BEING_CONSOLIDATED_SCENARIO_1");
  let f1 = async { await* handler.trigger(1) };
  await ledger.mock.set_fee(10);
  await ledger.mock.set_response([#Err(#BadFee { expected_fee = 10 })]);
  await ledger.mock.release_transfer(); // let transfer return
  await f1;
  assert state(handler) == (0, 0, 0); // consolidation failed with deposit reset
  assert journal.hasEvents([
    #feeUpdated({ new = 10; old = 5 }),
    #depositMinimumUpdated({ new = 11; old = 6 }),
    #withdrawalMinimumUpdated({ new = 11; old = 6 }),
    #depositFeeUpdated({ new = 10; old = 5 }),
    #withdrawalFeeUpdated({ new = 10; old = 5 }),
    #consolidationError(#BadFee({ expected_fee = 10 })),
    #issued(-5),
  ]);
  assert handler.userCredit(user1) == 0; // credit has been corrected after consolidation

  // increase fee while deposit is being consolidated (implicitly)
  // scenario 2: old_fee < new_fee < deposit
  // consolidation should fail and deposit should be adjusted with new fee
  await ledger.mock.set_balance(20);
  assert (await* handler.notify(user1)) == ?(20, 10);
  assert journal.hasEvents([
    #issued(+10),
    #newDeposit(20),
  ]);
  assert state(handler) == (20, 0, 1);
  await ledger.mock.lock_transfer("IMP_INCREASE_FEE_WHILE_DEPOSIT_IS_BEING_CONSOLIDATED_SCENARIO_2");
  let f2 = async { await* handler.trigger(1) };
  await ledger.mock.set_fee(15);
  await ledger.mock.set_response([#Err(#BadFee { expected_fee = 15 })]);
  await ledger.mock.release_transfer(); // let transfer return
  await f2;
  assert state(handler) == (20, 0, 1); // consolidation failed with updated deposit scheduled
  assert journal.hasEvents([
    #feeUpdated({ new = 15; old = 10 }),
    #depositMinimumUpdated({ new = 16; old = 11 }),
    #withdrawalMinimumUpdated({ new = 16; old = 11 }),
    #depositFeeUpdated({ new = 15; old = 10 }),
    #withdrawalFeeUpdated({ new = 15; old = 10 }),
    #consolidationError(#BadFee({ expected_fee = 15 })),
    #issued(-10),
    #issued(+5),
  ]);
  assert handler.userCredit(user1) == 5; // credit has been corrected after consolidation

  // increase fee while deposit is being consolidated (explicitly)
  // scenario 1: old_fee < deposit <= new_fee
  // consolidation should fail and deposit should be reset
  assert handler.userCredit(user1) == 5; // initial credit
  assert journal.hasEvents([]);
  assert state(handler) == (20, 0, 1);
  await ledger.mock.lock_transfer("EXP_INCREASE_FEE_WHILE_DEPOSIT_IS_BEING_CONSOLIDATED_SCENARIO_1");
  let f3 = async { await* handler.trigger(1) };
  await ledger.mock.set_fee(100);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 100; old = 15 }),
    #depositMinimumUpdated({ new = 101; old = 16 }),
    #withdrawalMinimumUpdated({ new = 101; old = 16 }),
    #depositFeeUpdated({ new = 100; old = 15 }),
    #withdrawalFeeUpdated({ new = 100; old = 15 }),
  ]);
  await ledger.mock.set_response([#Err(#BadFee { expected_fee = 100 })]);
  await ledger.mock.release_transfer(); // let transfer return
  await f3;
  assert state(handler) == (0, 0, 0); // consolidation failed with deposit reset
  assert journal.hasEvents([
    #consolidationError(#BadFee({ expected_fee = 100 })),
    #issued(-5),
  ]);
  assert handler.userCredit(user1) == 0; // credit has been corrected

  // increase fee while deposit is being consolidated (explicitly)
  // scenario 2: old_fee < new_fee < deposit
  // consolidation should fail and deposit should be adjusted with new fee
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();

  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 100 }),
    #depositMinimumUpdated({ new = 6; old = 101 }),
    #withdrawalMinimumUpdated({ new = 6; old = 101 }),
    #depositFeeUpdated({ new = 5; old = 100 }),
    #withdrawalFeeUpdated({ new = 5; old = 100 }),
  ]);
  assert (await* handler.notify(user1)) == ?(20, 15);
  assert journal.hasEvents([
    #issued(15),
    #newDeposit(20),
  ]);
  assert state(handler) == (20, 0, 1);
  await ledger.mock.lock_transfer("EXP_INCREASE_FEE_WHILE_DEPOSIT_IS_BEING_CONSOLIDATED_SCENARIO_2");
  let f4 = async { await* handler.trigger(1) };
  await ledger.mock.set_fee(6);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 6; old = 5 }),
    #depositMinimumUpdated({ new = 7; old = 6 }),
    #withdrawalMinimumUpdated({ new = 7; old = 6 }),
    #depositFeeUpdated({ new = 6; old = 5 }),
    #withdrawalFeeUpdated({ new = 6; old = 5 }),
  ]);
  await ledger.mock.set_response([#Err(#BadFee { expected_fee = 6 })]);
  await ledger.mock.release_transfer(); // let transfer return
  await f4;
  assert state(handler) == (20, 0, 1); // consolidation failed with updated deposit scheduled
  assert journal.hasEvents([
    #consolidationError(#BadFee({ expected_fee = 6 })),
    #issued(-15),
    #issued(14),
  ]);
  assert handler.userCredit(user1) == 14; // credit has been corrected

  // only 1 consolidation process can be triggered for same user at same time
  // consolidation with deposit > fee should be successful
  await ledger.mock.set_response([#Ok 42]);
  var transfer_count = await ledger.mock.transfer_count();
  let f5 = async { await* handler.trigger(1) };
  let f6 = async { await* handler.trigger(1) };
  await f5;
  await f6;
  await ledger.mock.set_balance(0);
  assert ((await ledger.mock.transfer_count())) == transfer_count + 1; // only 1 transfer call has been made
  assert state(handler) == (0, 14, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({ credited = 14; deducted = 20 })
  ]);
  assert handler.userCredit(user1) == 14; // credit unchanged

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // increase deposit again
  await ledger.mock.set_balance(20);
  assert (await* handler.notify(user1)) == ?(20, 15);
  assert state(handler) == (20, 0, 1);
  assert journal.hasEvents([
    #issued(15),
    #newDeposit(20),
  ]);

  // trigger consolidation again
  await ledger.mock.set_response([#Ok 42]);
  await* handler.trigger(1);
  await ledger.mock.set_balance(0);
  assert state(handler) == (0, 15, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({ credited = 15; deducted = 20 })
  ]);

  // withdraw (fee < amount < consolidated_funds)
  // should be successful
  await ledger.mock.set_fee(1);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 1; old = 5 }),
    #depositMinimumUpdated({ new = 2; old = 6 }),
    #withdrawalMinimumUpdated({ new = 2; old = 6 }),
    #depositFeeUpdated({ new = 1; old = 5 }),
    #withdrawalFeeUpdated({ new = 1; old = 5 }),
  ]);
  await ledger.mock.set_response([#Ok 42]);
  assert (await* handler.withdrawFromCredit(user1, account, 5)) == #ok(42, 4);
  assert journal.hasEvents([
    #burned(5),
    #withdraw({ amount = 5; to = account }),
  ]);
  assert state(handler) == (0, 10, 0);

  // withdraw (amount <= fee_)
  var transfer_count = await ledger.mock.transfer_count();
  await ledger.mock.set_response([#Ok 42]); // transfer call should not be executed anyway
  assert (await* handler.withdrawFromCredit(user1, account, 1)) == #err(#TooLowQuantity);
  assert (await ledger.mock.transfer_count()) == transfer_count; // no transfer call
  assert state(handler) == (0, 10, 0); // state unchanged
  assert journal.hasEvents([
    #burned(1),
    #withdrawalError(#TooLowQuantity),
    #issued(1),
  ]);

  // withdraw (consolidated_funds < amount)
  await ledger.mock.set_response([#Err(#InsufficientFunds({ balance = 10 }))]);
  assert (await* handler.withdrawFromCredit(user1, account, 100)) == #err(#InsufficientCredit);
  assert state(handler) == (0, 10, 0); // state unchanged
  assert journal.hasEvents([#withdrawalError(#InsufficientCredit)]);

  // increase fee while withdraw is being underway
  // scenario 1: old_fee < new_fee < amount
  // withdraw should fail and then retry successfully, fee should be updated
  await ledger.mock.lock_transfer("INCREASE_FEE_WITHDRAW_IS_BEING_UNDERWAY_SCENARIO_1");
  transfer_count := await ledger.mock.transfer_count();
  let f1 = async { await* handler.withdrawFromCredit(user1, account, 5) };
  await ledger.mock.set_fee(2);
  await ledger.mock.set_response([#Err(#BadFee { expected_fee = 2 }), #Ok 42]);
  await ledger.mock.release_transfer(); // let transfer return
  assert (await f1) == #ok(42, 3);
  assert (await ledger.mock.transfer_count()) == transfer_count + 2;
  assert journal.hasEvents([
    #burned(5),
    #feeUpdated({ new = 2; old = 1 }),
    #depositMinimumUpdated({ new = 3; old = 2 }),
    #withdrawalMinimumUpdated({ new = 3; old = 2 }),
    #depositFeeUpdated({ new = 2; old = 1 }),
    #withdrawalFeeUpdated({ new = 2; old = 1 }),
    #withdraw({ amount = 5; to = account }),
  ]);
  assert state(handler) == (0, 5, 0); // state has changed
  assert handler.debitUser(user1, 5);
  assert journal.hasEvents([
    #debited(5)
  ]);

  // increase fee while withdraw is being underway
  // scenario 2: old_fee < amount <= new_fee
  // withdraw should fail and then retry with failure, fee should be updated
  // the second call should be avoided with comparison amount and fee
  await ledger.mock.lock_transfer("INCREASE_FEE_WITHDRAW_IS_BEING_UNDERWAY_SCENARIO_2");
  transfer_count := await ledger.mock.transfer_count();
  let f2 = async { await* handler.withdrawFromPool(account, 4) };
  await ledger.mock.set_fee(4);
  await ledger.mock.set_response([#Err(#BadFee { expected_fee = 4 }), #Ok 42]); // the second call should not be executed
  await ledger.mock.release_transfer(); // let transfer return
  assert (await f2) == #err(#TooLowQuantity);
  assert (await ledger.mock.transfer_count()) == transfer_count + 1; // the second transfer call is avoided
  assert state(handler) == (0, 5, 0); // state unchanged
  assert journal.hasEvents([
    #burned(4),
    #feeUpdated({ new = 4; old = 2 }),
    #depositMinimumUpdated({ new = 5; old = 3 }),
    #withdrawalMinimumUpdated({ new = 5; old = 3 }),
    #depositFeeUpdated({ new = 4; old = 2 }),
    #withdrawalFeeUpdated({ new = 4; old = 2 }),
    #withdrawalError(#TooLowQuantity),
    #issued(+4),
  ]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // another user deposit + consolidation
  await ledger.mock.set_balance(300);
  assert (await* handler.notify(user2)) == ?(300, 295);
  assert journal.hasEvents([
    #issued(295),
    #newDeposit(300),
  ]);
  await ledger.mock.set_response([#Ok 42]);
  await* handler.trigger(1);
  await ledger.mock.set_balance(0);
  assert state(handler) == (0, 295, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({ credited = 295; deducted = 300 })
  ]);

  // increase deposit
  await ledger.mock.set_balance(20);
  assert (await* handler.notify(user1)) == ?(20, 15);
  assert state(handler) == (20, 295, 1);
  assert journal.hasEvents([
    #issued(+15),
    #newDeposit(20),
  ]);

  // trigger consolidation
  await ledger.mock.set_response([#Ok 42]);
  await* handler.trigger(1);
  await ledger.mock.set_balance(0);
  assert state(handler) == (0, 310, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({ credited = 15; deducted = 20 })
  ]);

  // withdraw from credit (fee < amount =< credit)
  // should be successful
  await ledger.mock.set_fee(1);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 1; old = 5 }),
    #depositMinimumUpdated({ new = 2; old = 6 }),
    #withdrawalMinimumUpdated({ new = 2; old = 6 }),
    #depositFeeUpdated({ new = 1; old = 5 }),
    #withdrawalFeeUpdated({ new = 1; old = 5 }),
  ]);
  await ledger.mock.set_response([#Ok 42]);
  assert (await* handler.withdrawFromCredit(user1, account, 5)) == #ok(42, 4);
  assert journal.hasEvents([
    #burned(5),
    #withdraw({ amount = 5; to = account }),
  ]);
  assert state(handler) == (0, 305, 0);
  assert handler.userCredit(user1) == 10;

  // withdraw from credit (amount <= fee_ =< credit)
  var transfer_count = await ledger.mock.transfer_count();
  await ledger.mock.set_response([#Ok 42]); // transfer call should not be executed anyway
  assert (await* handler.withdrawFromCredit(user1, account, 1)) == #err(#TooLowQuantity);
  assert (await ledger.mock.transfer_count()) == transfer_count; // no transfer call
  assert state(handler) == (0, 305, 0); // state unchanged
  assert journal.hasEvents([
    #burned(1),
    #withdrawalError(#TooLowQuantity),
    #issued(+1),
  ]);

  // withdraw from credit (credit < amount)
  // insufficient user credit
  transfer_count := await ledger.mock.transfer_count();
  await ledger.mock.set_response([#Ok 42]); // transfer call should not be executed anyway
  assert (await* handler.withdrawFromCredit(user1, account, 12)) == #err(#InsufficientCredit); // amount 12 > credit 10
  assert (await ledger.mock.transfer_count()) == transfer_count; // no transfer call
  assert state(handler) == (0, 305, 0); // state unchanged
  assert journal.hasEvents([
    #withdrawalError(#InsufficientCredit)
  ]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // Change fee while notify is underway with locked 0-deposit.
  // 0-deposits can be temporarily being stored in deposit registry because of being locked with #notify.
  // Deposit registry recalculation is triggered and credits related to 0-deposits should not be corrected there.

  // scenario 1: increase fee
  await ledger.mock.lock_balance("CHANGE_FEE_WHILE_NOTIFY_IS_UNDERWAY_WITH_LOCKED_0_DEPOSIT_SCENARIO_1");
  await ledger.mock.set_balance(5);
  let f1 = async { await* handler.notify(user1) };
  await ledger.mock.set_fee(6);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 6; old = 5 }),
    #depositMinimumUpdated({ new = 7; old = 6 }),
    #withdrawalMinimumUpdated({ new = 7; old = 6 }),
    #depositFeeUpdated({ new = 6; old = 5 }),
    #withdrawalFeeUpdated({ new = 6; old = 5 }),
  ]);
  await ledger.mock.release_balance(); // let notify return
  assert (await f1) == ?(0, 0);
  assert state(handler) == (0, 0, 0); // state unchanged because deposit has not changed
  assert handler.userCredit(user1) == 0; // credit should not be corrected
  assert journal.hasEvents([]);

  // scenario 2: decrease fee
  await ledger.mock.lock_balance("CHANGE_FEE_WHILE_NOTIFY_IS_UNDERWAY_WITH_LOCKED_0_DEPOSIT_SCENARIO_2");
  await ledger.mock.set_balance(5);
  let f2 = async { await* handler.notify(user1) };
  await ledger.mock.set_fee(2);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 2; old = 6 }),
    #depositMinimumUpdated({ new = 3; old = 7 }),
    #withdrawalMinimumUpdated({ new = 3; old = 7 }),
    #depositFeeUpdated({ new = 2; old = 6 }),
    #withdrawalFeeUpdated({ new = 2; old = 6 }),
  ]);
  await ledger.mock.release_balance(); // let notify return
  assert (await f2) == ?(5, 3);
  assert state(handler) == (5, 0, 1); // state unchanged because deposit has not changed
  assert handler.userCredit(user1) == 3; // credit should not be corrected
  assert journal.hasEvents([
    #issued(+3),
    #newDeposit(5),
  ]);

  // Recalculate credits related to deposits when fee changes

  // scenario 1: new_fee < prev_fee < deposit
  await ledger.mock.set_fee(1);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #issued(+1),
    #feeUpdated({ new = 1; old = 2 }),
    #depositMinimumUpdated({ new = 2; old = 3 }),
    #withdrawalMinimumUpdated({ new = 2; old = 3 }),
    #depositFeeUpdated({ new = 1; old = 2 }),
    #withdrawalFeeUpdated({ new = 1; old = 2 }),
  ]);
  assert handler.userCredit(user1) == 4; // credit corrected

  // scenario 2: prev_fee < new_fee < deposit
  await ledger.mock.set_fee(3);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #issued(-2),
    #feeUpdated({ new = 3; old = 1 }),
    #depositMinimumUpdated({ new = 4; old = 2 }),
    #withdrawalMinimumUpdated({ new = 4; old = 2 }),
    #depositFeeUpdated({ new = 3; old = 1 }),
    #withdrawalFeeUpdated({ new = 3; old = 1 }),
  ]);
  assert handler.userCredit(user1) == 2; // credit corrected

  // scenario 3: prev_fee < deposit <= new_fee
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #issued(-2),
    #feeUpdated({ new = 5; old = 3 }),
    #depositMinimumUpdated({ new = 6; old = 4 }),
    #withdrawalMinimumUpdated({ new = 6; old = 4 }),
    #depositFeeUpdated({ new = 5; old = 3 }),
    #withdrawalFeeUpdated({ new = 5; old = 3 }),
  ]);
  assert handler.userCredit(user1) == 0; // credit corrected

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // fetching fee should not overlap
  await ledger.mock.lock_fee("FETCHING_FEE_SHOULD_NOT_OVERLAP");
  await ledger.mock.set_fee(6);
  let f1 = async { await* handler.fetchFee() };
  let f2 = async { await* handler.fetchFee() };
  assert (await f2) == null;
  await ledger.mock.release_fee();
  assert (await f1) == ?6;
  assert journal.hasEvents([
    #feeUpdated({ new = 6; old = 5 }),
    #depositMinimumUpdated({ new = 7; old = 6 }),
    #withdrawalMinimumUpdated({ new = 7; old = 6 }),
    #depositFeeUpdated({ new = 6; old = 5 }),
    #withdrawalFeeUpdated({ new = 6; old = 5 }),
  ]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert handler.minimum(#deposit) == 6;
  assert handler.minimum(#withdrawal) == 6;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // set deposit minimum
  // case: min > fee
  handler.setMinimum(#deposit, 12);
  assert handler.minimum(#deposit) == 12;
  assert journal.hasEvents([
    #depositMinimumUpdated({ new = 12; old = 6 })
  ]);

  // set deposit minimum
  // case: min == prev_min
  handler.setMinimum(#deposit, 12);
  assert handler.minimum(#deposit) == 12;
  assert journal.hasEvents([]);

  // set deposit minimum
  // case: min < fee
  handler.setMinimum(#deposit, 4);
  assert handler.minimum(#deposit) == 6; // fee + 1
  assert journal.hasEvents([
    #depositMinimumUpdated({ new = 6; old = 12 })
  ]);

  // set deposit minimum
  // case: min == fee
  handler.setMinimum(#deposit, 5);
  assert handler.minimum(#deposit) == 6;
  assert journal.hasEvents([]);

  // notify
  // case: fee < balance < min
  handler.setMinimum(#deposit, 9);
  assert handler.minimum(#deposit) == 9;
  assert journal.hasEvents([
    #depositMinimumUpdated({ new = 9; old = 6 })
  ]);
  await ledger.mock.set_balance(8);
  assert (await* handler.notify(user1)) == ?(0, 0);
  assert journal.hasEvents([]);

  // notify
  // case: fee < min <= balance
  await ledger.mock.set_balance(9);
  assert (await* handler.notify(user1)) == ?(9, 4);
  assert journal.hasEvents([
    #issued(+4),
    #newDeposit(9),
  ]);

  // notify
  // case: fee < balance < min, old deposit exists
  // old deposit should not be reset because it was made before minimum increase
  handler.setMinimum(#deposit, 15);
  assert handler.minimum(#deposit) == 15;
  assert journal.hasEvents([
    #depositMinimumUpdated({ new = 15; old = 9 }),
  ]);
  await ledger.mock.set_balance(12);
  assert (await* handler.notify(user1)) == ?(0, 0); // deposit not updated
  assert journal.hasEvents([]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert handler.minimum(#deposit) == 6;
  assert handler.minimum(#withdrawal) == 6;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // increase deposit again
  await ledger.mock.set_balance(20);
  assert (await* handler.notify(user1)) == ?(20, 15);
  assert state(handler) == (20, 0, 1);
  assert journal.hasEvents([
    #issued(+15),
    #newDeposit(20),
  ]);

  // trigger consolidation again
  await ledger.mock.set_response([#Ok 42]);
  await* handler.trigger(1);
  await ledger.mock.set_balance(0);
  assert state(handler) == (0, 15, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({ credited = 15; deducted = 20 })
  ]);

  // set withdrawal minimum
  // case: min > fee
  handler.setMinimum(#withdrawal, 12);
  assert handler.minimum(#withdrawal) == 12;
  assert journal.hasEvents([
    #withdrawalMinimumUpdated({ new = 12; old = 6 })
  ]);

  // set withdrawal minimum
  // case: min == prev_min
  handler.setMinimum(#withdrawal, 12);
  assert handler.minimum(#withdrawal) == 12;
  assert journal.hasEvents([]);

  // set withdrawal minimum
  // case: min < fee
  handler.setMinimum(#withdrawal, 4);
  assert handler.minimum(#withdrawal) == 6; // fee + 1
  assert journal.hasEvents([
    #withdrawalMinimumUpdated({ new = 6; old = 12 })
  ]);

  // set withdrawal minimum
  // case: min == fee
  handler.setMinimum(#withdrawal, 5);
  assert handler.minimum(#withdrawal) == 6;
  assert journal.hasEvents([]);

  // increase withdrawal minimum
  handler.setMinimum(#withdrawal, 11);
  assert handler.minimum(#withdrawal) == 11;
  assert journal.hasEvents([#withdrawalMinimumUpdated({ new = 11; old = 6 })]);

  // withdraw
  // case: fee < amount < min
  var transfer_count = await ledger.mock.transfer_count();
  await ledger.mock.set_response([#Ok 42]); // transfer call should not be executed anyway
  assert (await* handler.withdrawFromCredit(user1, account, 6)) == #err(#TooLowQuantity);
  assert (await ledger.mock.transfer_count()) == transfer_count; // no transfer call
  assert state(handler) == (0, 15, 0); // state unchanged
  assert journal.hasEvents([
    #burned(6),
    #withdrawalError(#TooLowQuantity),
    #issued(+6),
  ]);

  // withdraw
  // case: fee < min <= amount
  await ledger.mock.set_response([#Ok 42]);
  assert (await* handler.withdrawFromCredit(user1, account, 11)) == #ok(42, 6);
  assert journal.hasEvents([
    #burned(11),
    #withdraw({ amount = 11; to = account }),
  ]);
  assert state(handler) == (0, 4, 0);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // credit pool
  handler.issue_(#pool, 20);
  assert handler.poolCredit() == 20;
  assert journal.hasEvents([#issued(+20)]);

  // debit pool
  handler.issue_(#pool, -5);
  assert handler.poolCredit() == 15;
  assert journal.hasEvents([#issued(-5)]);

  // credit user
  // case: pool credit < amount
  assert (handler.creditUser(user1, 30)) == false;
  assert journal.hasEvents([]);
  assert handler.poolCredit() == 15;
  assert handler.userCredit(user1) == 0;

  // credit user
  // case: pool credit <= amount
  assert (handler.creditUser(user1, 15)) == true;
  assert journal.hasEvents([#credited(15)]);
  assert handler.poolCredit() == 0;
  assert handler.userCredit(user1) == 15;

  // debit user
  // case: credit < amount
  assert (handler.debitUser(user1, 16)) == false;
  assert journal.hasEvents([]);
  assert handler.poolCredit() == 0;
  assert handler.userCredit(user1) == 15;

  // debit user
  // case: credit >= amount
  assert (handler.debitUser(user1, 15)) == true;
  assert journal.hasEvents([#debited(15)]);
  assert handler.poolCredit() == 15;
  assert handler.userCredit(user1) == 0;

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert handler.minimum(#deposit) == 6;
  assert handler.minimum(#withdrawal) == 6;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // set deposit fee
  // case: fee > ledger_fee
  handler.setFee(#deposit, 6);
  assert handler.fee(#deposit) == 6;
  assert journal.hasEvents([
    #depositFeeUpdated({ new = 6; old = 5 }),
    #depositMinimumUpdated({ new = 7; old = 6 }),
  ]);

  // set deposit fee
  // case: fee == prev_fee
  handler.setFee(#deposit, 6);
  assert handler.fee(#deposit) == 6;
  assert journal.hasEvents([]);

  // set deposit fee
  // case: fee < ledger_fee
  handler.setFee(#deposit, 4);
  assert handler.fee(#deposit) == 5;
  assert journal.hasEvents([
    #depositFeeUpdated({ new = 5; old = 6 }),
    #depositMinimumUpdated({ new = 6; old = 7 }),
  ]);

  // set deposit fee
  // case: fee == ledger_fee
  handler.setFee(#deposit, 4);
  assert handler.fee(#deposit) == 5;
  assert journal.hasEvents([]);

  // notify (balance > min)
  await ledger.mock.set_balance(13);
  assert (await* handler.notify(user1)) == ?(13, 8);
  assert journal.hasEvents([
    #issued(+8),
    #newDeposit(13),
  ]);

  // set deposit fee (new_min) > balance
  assert handler.userCredit(user1) == 8;
  handler.setFee(#deposit, 6);
  assert handler.fee(#deposit) == 6;
  assert journal.hasEvents([
    #issued(-1),
    #depositFeeUpdated({ new = 6; old = 5 }),
    #depositMinimumUpdated({ new = 7; old = 6 }),
  ]);
  assert handler.userCredit(user1) == 7; // credit corrected

  // trigger consolidation
  await ledger.mock.set_response([#Ok 42]);
  await* handler.trigger(1);
  await ledger.mock.set_balance(0);
  assert state(handler) == (0, 7, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({ credited = 7; deducted = 13 })
  ]);

  // set withdrawal fee
  // case: fee > ledger_fee
  handler.setFee(#withdrawal, 6);
  assert handler.fee(#withdrawal) == 6;
  assert journal.hasEvents([
    #withdrawalFeeUpdated({ new = 6; old = 5 }),
    #withdrawalMinimumUpdated({ new = 7; old = 6 }),
  ]);

  // set withdrawal fee
  // case: fee == prev_fee
  handler.setFee(#withdrawal, 6);
  assert handler.fee(#withdrawal) == 6;
  assert journal.hasEvents([]);

  // set withdrawal fee
  // case: fee < ledger_fee
  handler.setFee(#withdrawal, 4);
  assert handler.fee(#withdrawal) == 5;
  assert journal.hasEvents([
    #withdrawalFeeUpdated({ new = 5; old = 6 }),
    #withdrawalMinimumUpdated({ new = 6; old = 7 }),
  ]);

  // set withdrawal fee
  // case: fee == ledger_fee
  handler.setFee(#withdrawal, 4);
  assert handler.fee(#withdrawal) == 5;
  assert journal.hasEvents([]);

  // decrease ledger fee (ledger_fee < withdrawal_fee)
  await ledger.mock.set_fee(2);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 2;
  assert handler.minimum(#withdrawal) == 5; // withdrawal_fee + 1
  assert journal.hasEvents([
    #feeUpdated({ new = 2; old = 5 }),
    #withdrawalMinimumUpdated({ new = 5; old = 6 }),
    #withdrawalFeeUpdated({ new = 4; old = 5 }),
  ]);

  // withdrawal with defined withdrawal fee
  await ledger.mock.set_response([#Ok 42]);
  assert (await* handler.withdrawFromCredit(user1, account, 5)) == #ok(42, 1);
  assert journal.hasEvents([
    #burned(5),
    #withdraw({ amount = 5; to = account }),
  ]);
  assert state(handler) == (0, 2, 0);
  assert handler.userCredit(user1) == 2;

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert handler.minimum(#deposit) == 6;
  assert handler.minimum(#withdrawal) == 6;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // deposit from allowance < amount + fee
  await ledger.mock.set_transfer_from_res([#Err(#InsufficientAllowance({ allowance = 8 }))]);
  assert (await* handler.depositFromAllowance(user1, user1_account, 9)) == #err(#InsufficientAllowance({ allowance = 8 }));
  assert state(handler) == (0, 0, 0);
  assert journal.hasEvents([
    #allowanceError(#InsufficientAllowance({ allowance = 8 }))
  ]);

  // deposit from allowance >= amount + fee
  await ledger.mock.set_transfer_from_res([#Ok 42]);
  assert (await* handler.depositFromAllowance(user1, user1_account, 8)) == #ok(8, 42);
  assert handler.userCredit(user1) == 8;
  assert state(handler) == (0, 8, 0);
  assert journal.hasEvents([
    #issued(+8),
    #allowanceDrawn({ credited = 8 }),
  ]);

  // deposit from allowance <= fee
  await ledger.mock.set_transfer_from_res([#Ok 42]); // should be not called
  var transfer_from_count = await ledger.mock.transfer_from_count();
  assert (await* handler.depositFromAllowance(user1, user1_account, 5)) == #err(#TooLowQuantity);
  assert handler.userCredit(user1) == 8; // not changed
  assert state(handler) == (0, 8, 0); // not changed
  assert transfer_from_count == (await ledger.mock.transfer_from_count());
  assert journal.hasEvents([
    #allowanceError(#TooLowQuantity)
  ]);

  // deposit from allowance >= amount
  // caller principal != account owner
  await ledger.mock.set_transfer_from_res([#Ok 42]);
  assert (await* handler.depositFromAllowance(user1, user2_account, 9)) == #ok(9, 42);
  assert handler.userCredit(user1) == 17;
  assert state(handler) == (0, 17, 0);
  assert journal.hasEvents([
    #issued(+9),
    #allowanceDrawn({ credited = 9 }),
  ]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // notify with 0 balance
  await ledger.mock.set_balance(0);
  assert (await* handler.notify(user1)) == ?(0, 0);

  assert handler.notificationsOnPause() == false;

  // pause notifications
  handler.pauseNotifications();
  assert handler.notificationsOnPause() == true;

  // notify with 0 balance
  assert (await* handler.notify(user1)) == null;

  // unpause notifications
  handler.unpauseNotifications();
  assert handler.notificationsOnPause() == false;

  // notify with 0 balance
  assert (await* handler.notify(user1)) == ?(0, 0);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  // Check whether the consolidation planned after the notification is successful.

  let (handler, journal) = createHandler(true);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.fee(#deposit) == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // notify with balance > fee
  await ledger.mock.set_balance(6);
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state(handler) == (6, 0, 1);
  assert journal.hasEvents([
    #issued(+1),
    #newDeposit(6),
  ]);

  // wait for consolidation
  await async {};
  await async {};

  assert state(handler) == (0, 1, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({ credited = 1; deducted = 6 })
  ]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

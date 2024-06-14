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
  assert journal.hasSize(0);

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated

  // notify with 0 balance
  await ledger.mock.set_balance(0);
  assert (await* handler.notify(user1)) == ?(0, 0);
  assert state(handler) == (0, 0, 0);
  assert journal.hasSize(0);

  // notify with balance <= fee
  await ledger.mock.set_balance(5);
  assert (await* handler.notify(user1)) == ?(0, 0);
  assert state(handler) == (0, 0, 0);
  assert journal.hasSize(0);

  // notify with balance > fee
  await ledger.mock.set_balance(6);
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state(handler) == (6, 0, 1);
  assert journal.hasSize(2); // #newDeposit, #issued

  // increase fee while item still in queue (trigger did not run yet)
  await ledger.mock.set_fee(6);
  ignore await* handler.fetchFee();
  assert state(handler) == (0, 0, 0); // recalculation after fee update
  assert journal.hasSize(6); // #feeUpdated, #issued, #depositMinimumUpdated, #withdrawalMinimumUpdated, #depositFeeUpdated, #withdrawalFeeUpdated

  // increase deposit again
  await ledger.mock.set_balance(7);
  assert (await* handler.notify(user1)) == ?(7, 1);
  assert state(handler) == (7, 0, 1);
  assert journal.hasSize(2); // #newDeposit, #issued

  // increase fee while notify is underway (and item still in queue)
  // scenario 1: old_fee < previous = latest <= new_fee
  // this means no new deposit has happened (latest = previous)
  await ledger.mock.lock_balance("INCREASE_FEE_WHILE_NOTIFY_IS_UNDERWAY_SCENARIO_1");
  let f1 = async { await* handler.notify(user1) };
  await ledger.mock.set_fee(10); // fee 6 -> 10
  assert state(handler) == (7, 0, 1); // state from before
  ignore await* handler.fetchFee();
  assert journal.hasSize(6); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #issued, #depositMinimumUpdated, #withdrawalMinimumUpdated
  assert state(handler) == (0, 0, 0); // state changed
  await ledger.mock.release_balance(); // let notify return
  assert (await f1) == ?(0, 0); // deposit <= new fee
  assert journal.hasSize(0);

  // increase deposit again
  await ledger.mock.set_balance(15);
  assert (await* handler.notify(user1)) == ?(15, 5);
  assert state(handler) == (15, 0, 1);
  assert journal.hasSize(2); // #newDeposit, #issued

  // increase fee while notify is underway (and item still in queue)
  // scenario 2: old_fee < previous <= new_fee < latest
  await ledger.mock.set_balance(20);
  await ledger.mock.lock_balance("INCREASE_FEE_WHILE_NOTIFY_IS_UNDERWAY_SCENARIO_2");
  let f2 = async { await* handler.notify(user1) }; // would return ?(5, _) at old fee
  await ledger.mock.set_fee(15); // fee 10 -> 15
  assert state(handler) == (15, 0, 1); // state from before
  ignore await* handler.fetchFee();
  assert journal.hasSize(6); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #issued, #depositMinimumUpdated, #withdrawalMinimumUpdated
  assert state(handler) == (0, 0, 0); // state changed
  await ledger.mock.release_balance(); // let notify return
  assert (await f2) == ?(20, 5); // credit = latest - new_fee
  assert state(handler) == (20, 0, 1); // state should have changed
  assert journal.hasSize(2); // #newDeposit, #issued

  // decrease fee while notify is underway (and item still in queue)
  // new_fee < old_fee < previous == latest
  await ledger.mock.lock_balance("DECREASE_FEE_WHILE_NOTIFY_IS_UNDERWAY");
  let f3 = async { await* handler.notify(user1) };
  await ledger.mock.set_fee(10); // fee 15 -> 10
  assert state(handler) == (20, 0, 1); // state from before
  ignore await* handler.fetchFee();
  assert journal.hasSize(6); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #issued, #depositMinimumUpdated, #withdrawalMinimumUpdated
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
  assert journal.hasSize(0);

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
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated

  // notify 1
  await ledger.mock.set_balance(7);
  assert (await* handler.notify(user1)) == ?(7, 2);
  assert handler.userCredit(user1) == 2;
  assert state(handler) == (7, 0, 1);
  assert journal.hasSize(2); // #newDeposit, #issued

  // notify 2
  await ledger.mock.set_balance(17);
  assert (await* handler.notify(user1)) == ?(10, 10);
  assert handler.userCredit(user1) == 12;
  assert state(handler) == (17, 0, 1);
  assert journal.hasSize(2); // #newDeposit, #issued
};

do {
  let (handler, journal) = createHandler(false);
  await ledger.mock.reset_state();

  // update fee first time
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasSize(5); // #feeUpdated,  #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated

  // increase fee while deposit is being consolidated (implicitly)
  // scenario 1: old_fee < deposit <= new_fee
  // consolidation should fail and deposit should be reset
  await ledger.mock.set_balance(10);
  assert (await* handler.notify(user1)) == ?(10, 5);
  assert journal.hasSize(2); // #issued, #newDeposit
  assert state(handler) == (10, 0, 1);
  await ledger.mock.lock_transfer("IMP_INCREASE_FEE_WHILE_DEPOSIT_IS_BEING_CONSOLIDATED_SCENARIO_1");
  let f1 = async { await* handler.trigger(1) };
  await ledger.mock.set_fee(10);
  await ledger.mock.set_response([#Err(#BadFee { expected_fee = 10 })]);
  await ledger.mock.release_transfer(); // let transfer return
  await f1;
  assert state(handler) == (0, 0, 0); // consolidation failed with deposit reset
  assert journal.hasSize(7); // #consolidationError, #issued, #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated
  assert handler.userCredit(user1) == 0; // credit has been corrected after consolidation

  // increase fee while deposit is being consolidated (implicitly)
  // scenario 2: old_fee < new_fee < deposit
  // consolidation should fail and deposit should be adjusted with new fee
  await ledger.mock.set_balance(20);
  assert (await* handler.notify(user1)) == ?(20, 10);
  assert journal.hasSize(2); // #issued, #newDeposit
  assert state(handler) == (20, 0, 1);
  await ledger.mock.lock_transfer("IMP_INCREASE_FEE_WHILE_DEPOSIT_IS_BEING_CONSOLIDATED_SCENARIO_2");
  let f2 = async { await* handler.trigger(1) };
  await ledger.mock.set_fee(15);
  await ledger.mock.set_response([#Err(#BadFee { expected_fee = 15 })]);
  await ledger.mock.release_transfer(); // let transfer return
  await f2;
  assert state(handler) == (20, 0, 1); // consolidation failed with updated deposit scheduled
  assert journal.hasSize(8); // #consolidationError, #issued, #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #issued, #depositMinimumUpdated, #withdrawalMinimumUpdated
  assert handler.userCredit(user1) == 5; // credit has been corrected after consolidation

  // increase fee while deposit is being consolidated (explicitly)
  // scenario 1: old_fee < deposit <= new_fee
  // consolidation should fail and deposit should be reset
  assert handler.userCredit(user1) == 5; // initial credit
  assert journal.hasSize(0);
  assert state(handler) == (20, 0, 1);
  await ledger.mock.lock_transfer("EXP_INCREASE_FEE_WHILE_DEPOSIT_IS_BEING_CONSOLIDATED_SCENARIO_1");
  let f3 = async { await* handler.trigger(1) };
  await ledger.mock.set_fee(100);
  ignore await* handler.fetchFee();
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated
  await ledger.mock.set_response([#Err(#BadFee { expected_fee = 100 })]);
  await ledger.mock.release_transfer(); // let transfer return
  await f3;
  assert state(handler) == (0, 0, 0); // consolidation failed with deposit reset
  assert journal.hasSize(2); // #consolidationError, #issued
  assert handler.userCredit(user1) == 0; // credit has been corrected

  // increase fee while deposit is being consolidated (explicitly)
  // scenario 2: old_fee < new_fee < deposit
  // consolidation should fail and deposit should be adjusted with new fee
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated
  assert (await* handler.notify(user1)) == ?(20, 15);
  assert journal.hasSize(2); // #issued, #newDeposit
  assert state(handler) == (20, 0, 1);
  await ledger.mock.lock_transfer("EXP_INCREASE_FEE_WHILE_DEPOSIT_IS_BEING_CONSOLIDATED_SCENARIO_2");
  let f4 = async { await* handler.trigger(1) };
  await ledger.mock.set_fee(6);
  ignore await* handler.fetchFee();
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated
  await ledger.mock.set_response([#Err(#BadFee { expected_fee = 6 })]);
  await ledger.mock.release_transfer(); // let transfer return
  await f4;
  assert state(handler) == (20, 0, 1); // consolidation failed with updated deposit scheduled
  assert journal.hasSize(3); // #consolidationError, #issued, #issued
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
  assert journal.hasSize(1); // #consolidated
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
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated

  // increase deposit again
  await ledger.mock.set_balance(20);
  assert (await* handler.notify(user1)) == ?(20, 15);
  assert state(handler) == (20, 0, 1);
  assert journal.hasSize(2); // #newDeposit, #issued

  // trigger consolidation again
  await ledger.mock.set_response([#Ok 42]);
  await* handler.trigger(1);
  await ledger.mock.set_balance(0);
  assert state(handler) == (0, 15, 0); // consolidation successful
  assert journal.hasSize(1); // #consolidated

  // withdraw (fee < amount < consolidated_funds)
  // should be successful
  await ledger.mock.set_fee(1);
  ignore await* handler.fetchFee();
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated
  await ledger.mock.set_response([#Ok 42]);
  assert (await* handler.withdrawFromCredit(user1, account, 5)) == #ok(42, 4);
  assert journal.hasSize(2); // #burned, #withdraw
  assert state(handler) == (0, 10, 0);

  // withdraw (amount <= fee_)
  var transfer_count = await ledger.mock.transfer_count();
  await ledger.mock.set_response([#Ok 42]); // transfer call should not be executed anyway
  assert (await* handler.withdrawFromCredit(user1, account, 1)) == #err(#TooLowQuantity);
  assert (await ledger.mock.transfer_count()) == transfer_count; // no transfer call
  assert state(handler) == (0, 10, 0); // state unchanged
  assert journal.hasSize(3); // #burned, #withdrawError, #issued

  // withdraw (consolidated_funds < amount)
  await ledger.mock.set_response([#Err(#InsufficientFunds({ balance = 10 }))]);
  assert (await* handler.withdrawFromCredit(user1, account, 100)) == #err(#InsufficientCredit);
  assert state(handler) == (0, 10, 0); // state unchanged
  assert journal.hasSize(1); // #withdrawError

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
  assert journal.hasSize(7); // #burned, #feeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated, depositFeeUpdated, withdrawalFeeUpdated, #withdraw
  assert state(handler) == (0, 5, 0); // state has changed
  assert handler.debitUser(user1, 5);
  assert journal.hasSize(1); // #issued

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
  assert journal.hasSize(8); // #burned, #feeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #withdrawalError, #issued

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
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated

  // another user deposit + consolidation
  await ledger.mock.set_balance(300);
  assert (await* handler.notify(user2)) == ?(300, 295);
  assert journal.hasSize(2); // #newDeposit, #issued
  await ledger.mock.set_response([#Ok 42]);
  await* handler.trigger(1);
  await ledger.mock.set_balance(0);
  assert state(handler) == (0, 295, 0); // consolidation successful
  assert journal.hasSize(1); // #consolidated

  // increase deposit
  await ledger.mock.set_balance(20);
  assert (await* handler.notify(user1)) == ?(20, 15);
  assert state(handler) == (20, 295, 1);
  assert journal.hasSize(2); // #newDeposit, #issued

  // trigger consolidation
  await ledger.mock.set_response([#Ok 42]);
  await* handler.trigger(1);
  await ledger.mock.set_balance(0);
  assert state(handler) == (0, 310, 0); // consolidation successful
  assert journal.hasSize(1); // #consolidated

  // withdraw from credit (fee < amount =< credit)
  // should be successful
  await ledger.mock.set_fee(1);
  ignore await* handler.fetchFee();
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated
  await ledger.mock.set_response([#Ok 42]);
  assert (await* handler.withdrawFromCredit(user1, account, 5)) == #ok(42, 4);
  assert journal.hasSize(2); // #withdraw, #issued
  assert state(handler) == (0, 305, 0);
  assert handler.userCredit(user1) == 10;

  // withdraw from credit (amount <= fee_ =< credit)
  var transfer_count = await ledger.mock.transfer_count();
  await ledger.mock.set_response([#Ok 42]); // transfer call should not be executed anyway
  assert (await* handler.withdrawFromCredit(user1, account, 1)) == #err(#TooLowQuantity);
  assert (await ledger.mock.transfer_count()) == transfer_count; // no transfer call
  assert state(handler) == (0, 305, 0); // state unchanged
  assert journal.hasSize(3); // #burned, #withdrawError, #issued

  // withdraw from credit (credit < amount)
  // insufficient user credit
  transfer_count := await ledger.mock.transfer_count();
  await ledger.mock.set_response([#Ok 42]); // transfer call should not be executed anyway
  assert (await* handler.withdrawFromCredit(user1, account, 12)) == #err(#InsufficientCredit); // amount 12 > credit 10
  assert (await ledger.mock.transfer_count()) == transfer_count; // no transfer call
  assert state(handler) == (0, 305, 0); // state unchanged
  assert journal.hasSize(1); // #withdrawError

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
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated

  // Change fee while notify is underway with locked 0-deposit.
  // 0-deposits can be temporarily being stored in deposit registry because of being locked with #notify.
  // Deposit registry recalculation is triggered and credits related to 0-deposits should not be corrected there.

  // scenario 1: increase fee
  await ledger.mock.lock_balance("CHANGE_FEE_WHILE_NOTIFY_IS_UNDERWAY_WITH_LOCKED_0_DEPOSIT_SCENARIO_1");
  await ledger.mock.set_balance(5);
  let f1 = async { await* handler.notify(user1) };
  await ledger.mock.set_fee(6);
  ignore await* handler.fetchFee();
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated
  await ledger.mock.release_balance(); // let notify return
  assert (await f1) == ?(0, 0);
  assert state(handler) == (0, 0, 0); // state unchanged because deposit has not changed
  assert handler.userCredit(user1) == 0; // credit should not be corrected
  assert journal.hasSize(0);

  // scenario 2: decrease fee
  await ledger.mock.lock_balance("CHANGE_FEE_WHILE_NOTIFY_IS_UNDERWAY_WITH_LOCKED_0_DEPOSIT_SCENARIO_2");
  await ledger.mock.set_balance(5);
  let f2 = async { await* handler.notify(user1) };
  await ledger.mock.set_fee(2);
  ignore await* handler.fetchFee();
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated
  await ledger.mock.release_balance(); // let notify return
  assert (await f2) == ?(5, 3);
  assert state(handler) == (5, 0, 1); // state unchanged because deposit has not changed
  assert handler.userCredit(user1) == 3; // credit should not be corrected
  assert journal.hasSize(2); // #issued, #newDeposit

  // Recalculate credits related to deposits when fee changes

  // scenario 1: new_fee < prev_fee < deposit
  await ledger.mock.set_fee(1);
  ignore await* handler.fetchFee();
  assert journal.hasSize(6); // #feeUpdated, #issued, #depositMinimumUpdated, #withdrawalMinimumUpdated, #depositFeeUpdated, #withdrawalFeeUpdated
  assert handler.userCredit(user1) == 4; // credit corrected

  // scenario 2: prev_fee < new_fee < deposit
  await ledger.mock.set_fee(3);
  ignore await* handler.fetchFee();
  assert journal.hasSize(6); // #feeUpdated, #issued, #depositMinimumUpdated, #withdrawalMinimumUpdated, #depositFeeUpdated, #withdrawalFeeUpdated
  assert handler.userCredit(user1) == 2; // credit corrected

  // scenario 3: prev_fee < deposit <= new_fee
  await ledger.mock.set_fee(5);
  ignore await* handler.fetchFee();
  assert journal.hasSize(6); // #feeUpdated, #issued, #depositMinimumUpdated, #withdrawalMinimumUpdated, #depositFeeUpdated, #withdrawalFeeUpdated
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
  assert journal.hasSize(5); // #feeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated, #depositFeeUpdated, #withdrawalFeeUpdated

  // fetching fee should not overlap
  await ledger.mock.lock_fee("FETCHING_FEE_SHOULD_NOT_OVERLAP");
  await ledger.mock.set_fee(6);
  let f1 = async { await* handler.fetchFee() };
  let f2 = async { await* handler.fetchFee() };
  assert (await f2) == null;
  await ledger.mock.release_fee();
  assert (await f1) == ?6;
  assert journal.hasSize(5); // #feeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated, #depositFeeUpdated, #withdrawalFeeUpdated

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
  assert journal.hasSize(5); // #feeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated, #depositFeeUpdated, #withdrawalFeeUpdated

  // set deposit minimum
  // case: min > fee
  handler.setMinimum(#deposit, 12);
  assert handler.minimum(#deposit) == 12;
  assert journal.hasSize(1); // #depositMinimumUpdated

  // set deposit minimum
  // case: min == prev_min
  handler.setMinimum(#deposit, 12);
  assert handler.minimum(#deposit) == 12;
  assert journal.hasSize(0);

  // set deposit minimum
  // case: min < fee
  handler.setMinimum(#deposit, 4);
  assert handler.minimum(#deposit) == 6; // fee + 1
  assert journal.hasSize(1); // #depositMinimumUpdated

  // set deposit minimum
  // case: min == fee
  handler.setMinimum(#deposit, 5);
  assert handler.minimum(#deposit) == 6;
  assert journal.hasSize(0);

  // notify
  // case: fee < balance < min
  handler.setMinimum(#deposit, 9);
  assert handler.minimum(#deposit) == 9;
  assert journal.hasSize(1); // #depositMinimumUpdated
  await ledger.mock.set_balance(8);
  assert (await* handler.notify(user1)) == ?(0, 0);
  assert journal.hasSize(0);

  // notify
  // case: fee < min <= balance
  await ledger.mock.set_balance(9);
  assert (await* handler.notify(user1)) == ?(9, 4);
  assert journal.hasSize(2); // #issued, #newDeposit

  // notify
  // case: fee < balance < min, old deposit exists
  // old deposit should not be reset because it was made before minimum increase
  handler.setMinimum(#deposit, 15);
  assert handler.minimum(#deposit) == 15;
  assert journal.hasSize(1); // #depositMinimumUpdated
  await ledger.mock.set_balance(12);
  assert (await* handler.notify(user1)) == ?(0, 0); // deposit not updated
  assert journal.hasSize(0);

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
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated

  // increase deposit again
  await ledger.mock.set_balance(20);
  assert (await* handler.notify(user1)) == ?(20, 15);
  assert state(handler) == (20, 0, 1);
  assert journal.hasSize(2); // #newDeposit, #issued

  // trigger consolidation again
  await ledger.mock.set_response([#Ok 42]);
  await* handler.trigger(1);
  await ledger.mock.set_balance(0);
  assert state(handler) == (0, 15, 0); // consolidation successful
  assert journal.hasSize(1); // #consolidated

  // set withdrawal minimum
  // case: min > fee
  handler.setMinimum(#withdrawal, 12);
  assert handler.minimum(#withdrawal) == 12;
  assert journal.hasSize(1); // #withdrawalMinimumUpdated

  // set withdrawal minimum
  // case: min == prev_min
  handler.setMinimum(#withdrawal, 12);
  assert handler.minimum(#withdrawal) == 12;
  assert journal.hasSize(0);

  // set withdrawal minimum
  // case: min < fee
  handler.setMinimum(#withdrawal, 4);
  assert handler.minimum(#withdrawal) == 6; // fee + 1
  assert journal.hasSize(1); // #depositMinimumUpdated

  // set withdrawal minimum
  // case: min == fee
  handler.setMinimum(#withdrawal, 5);
  assert handler.minimum(#withdrawal) == 6;
  assert journal.hasSize(0);

  // increase withdrawal minimum
  handler.setMinimum(#withdrawal, 11);
  assert handler.minimum(#withdrawal) == 11;
  assert journal.hasSize(1); // #withdrawalMinimumUpdated

  // withdraw
  // case: fee < amount < min
  var transfer_count = await ledger.mock.transfer_count();
  await ledger.mock.set_response([#Ok 42]); // transfer call should not be executed anyway
  assert (await* handler.withdrawFromCredit(user1, account, 6)) == #err(#TooLowQuantity);
  assert (await ledger.mock.transfer_count()) == transfer_count; // no transfer call
  assert state(handler) == (0, 15, 0); // state unchanged
  assert journal.hasSize(3); // #burned, #withdrawError, #issued

  // withdraw
  // case: fee < min <= amount
  await ledger.mock.set_response([#Ok 42]);
  assert (await* handler.withdrawFromCredit(user1, account, 11)) == #ok(42, 6);
  assert journal.hasSize(2); // #burned, #withdraw
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
  assert journal.hasSize(1); // #issued

  // debit pool
  handler.issue_(#pool, -5);
  assert handler.poolCredit() == 15;
  assert journal.hasSize(1); // #issued

  // credit user
  // case: pool credit < amount
  assert (handler.creditUser(user1, 30)) == false;
  assert journal.hasSize(0);
  assert handler.poolCredit() == 15;
  assert handler.userCredit(user1) == 0;

  // credit user
  // case: pool credit <= amount
  assert (handler.creditUser(user1, 15)) == true;
  assert journal.hasSize(1); // #credited
  assert handler.poolCredit() == 0;
  assert handler.userCredit(user1) == 15;

  // debit user
  // case: credit < amount
  assert (handler.debitUser(user1, 16)) == false;
  assert journal.hasSize(0);
  assert handler.poolCredit() == 0;
  assert handler.userCredit(user1) == 15;

  // debit user
  // case: credit >= amount
  assert (handler.debitUser(user1, 15)) == true;
  assert journal.hasSize(1); // #debited
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
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated

  // set deposit fee
  // case: fee > ledger_fee
  handler.setFee(#deposit, 6);
  assert handler.fee(#deposit) == 6;
  assert journal.hasSize(2); // #depositFeeUpdated, #depositMinimumUpdated

  // set deposit fee
  // case: fee == prev_fee
  handler.setFee(#deposit, 6);
  assert handler.fee(#deposit) == 6;
  assert journal.hasSize(0);

  // set deposit fee
  // case: fee < ledger_fee
  handler.setFee(#deposit, 4);
  assert handler.fee(#deposit) == 5;
  assert journal.hasSize(2); // #depositFeeUpdated, #depositMinimumUpdated

  // set deposit fee
  // case: fee == ledger_fee
  handler.setFee(#deposit, 4);
  assert handler.fee(#deposit) == 5;
  assert journal.hasSize(0);

  // notify (balance > min)
  await ledger.mock.set_balance(13);
  assert (await* handler.notify(user1)) == ?(13, 8);
  assert journal.hasSize(2); // #issued, #newDeposit

  // set deposit fee (new_min) > balance
  assert handler.userCredit(user1) == 8;
  handler.setFee(#deposit, 6);
  assert handler.fee(#deposit) == 6;
  assert journal.hasSize(3); // #depositFeeUpdated, #depositMinimumUpdated, #issued
  assert handler.userCredit(user1) == 7; // credit corrected

  // trigger consolidation
  await ledger.mock.set_response([#Ok 42]);
  await* handler.trigger(1);
  await ledger.mock.set_balance(0);
  assert state(handler) == (0, 7, 0); // consolidation successful
  assert journal.hasSize(1); // #consolidated

  // set withdrawal fee
  // case: fee > ledger_fee
  handler.setFee(#withdrawal, 6);
  assert handler.fee(#withdrawal) == 6;
  assert journal.hasSize(2); // #withdrawalFeeUpdated, #withdrawalMinimumUpdated

  // set withdrawal fee
  // case: fee == prev_fee
  handler.setFee(#withdrawal, 6);
  assert handler.fee(#withdrawal) == 6;
  assert journal.hasSize(0);

  // set withdrawal fee
  // case: fee < ledger_fee
  handler.setFee(#withdrawal, 4);
  assert handler.fee(#withdrawal) == 5;
  assert journal.hasSize(2); // #withdrawalFeeUpdated, #withdrawalMinimumUpdated

  // set withdrawal fee
  // case: fee == ledger_fee
  handler.setFee(#withdrawal, 4);
  assert handler.fee(#withdrawal) == 5;
  assert journal.hasSize(0);

  // decrease ledger fee (ledger_fee < withdrawal_fee)
  await ledger.mock.set_fee(2);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 2;
  assert handler.minimum(#withdrawal) == 5; // withdrawal_fee + 1
  assert journal.hasSize(3); // #feeUpdated, #withdrawalFeeUpdated, #withdrawalMinimumUpdated

  // withdrawal with defined withdrawal fee
  await ledger.mock.set_response([#Ok 42]);
  assert (await* handler.withdrawFromCredit(user1, account, 5)) == #ok(42, 1);
  assert journal.hasSize(2); // #withdraw, #issued
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
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated

  // deposit from allowance < amount + fee
  await ledger.mock.set_transfer_from_res([#Err(#InsufficientAllowance({ allowance = 8 }))]);
  assert (await* handler.depositFromAllowance(user1, user1_account, 9)) == #err(#InsufficientAllowance({ allowance = 8 }));
  assert state(handler) == (0, 0, 0);
  assert journal.hasSize(1); // #allowanceError

  // deposit from allowance >= amount + fee
  await ledger.mock.set_transfer_from_res([#Ok 42]);
  assert (await* handler.depositFromAllowance(user1, user1_account, 8)) == #ok(8, 42);
  assert handler.userCredit(user1) == 8;
  assert state(handler) == (0, 8, 0);
  assert journal.hasSize(2); // #allowanceDrawn, #issued

  // deposit from allowance <= fee
  await ledger.mock.set_transfer_from_res([#Ok 42]); // should be not called
  var transfer_from_count = await ledger.mock.transfer_from_count();
  assert (await* handler.depositFromAllowance(user1, user1_account, 5)) == #err(#TooLowQuantity);
  assert handler.userCredit(user1) == 8; // not changed
  assert state(handler) == (0, 8, 0); // not changed
  assert transfer_from_count == (await ledger.mock.transfer_from_count());
  assert journal.hasSize(1); // #allowanceError

  // deposit from allowance >= amount
  // caller principal != account owner
  await ledger.mock.set_transfer_from_res([#Ok 42]);
  assert (await* handler.depositFromAllowance(user1, user2_account, 9)) == #ok(9, 42);
  assert handler.userCredit(user1) == 17;
  assert state(handler) == (0, 17, 0);
  assert journal.hasSize(2); // #allowanceDrawn, #credited, #issued

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
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated

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
  assert journal.hasSize(5); // #feeUpdated, #depositFeeUpdated, #withdrawalFeeUpdated, #depositMinimumUpdated, #withdrawalMinimumUpdated

  // notify with balance > fee
  await ledger.mock.set_balance(6);
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state(handler) == (6, 0, 1);
  assert journal.hasSize(2); // #newDeposit, #credited

  // wait for consolidation
  await async {};
  await async {};

  assert state(handler) == (0, 1, 0); // consolidation successful
  assert journal.hasSize(1); // #consolidated

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

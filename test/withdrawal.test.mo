import Principal "mo:base/Principal";

import Util "util/common";
import MockLedger "util/mock_ledger";

let user1 = Principal.fromBlob("1");
let account = { owner = Principal.fromBlob("o"); subaccount = null };
let verbose = false;

do {
  let mock_ledger = await MockLedger.MockLedger();
  let (handler, journal, state, _) = Util.createHandler(mock_ledger, false, verbose);

  // update fee first time
  await mock_ledger.set_fee(3);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 3;
  assert journal.hasEvents([
    #feeUpdated({ new = 3; old = 0 }),
  ]);

  // update surcharge
  handler.setSurcharge(2);
  assert handler.surcharge() == 2;
  assert journal.hasEvents([
    #surchargeUpdated({ new = 2; old = 0 }),
  ]);

  // increase deposit again
  await mock_ledger.set_balance(20);
  assert (await* handler.notify(user1)) == ?(20, 15);
  assert state() == (20, 0, 1);
  assert journal.hasEvents([
    #issued(15),
    #newDeposit(20),
  ]);

  // trigger consolidation
  await mock_ledger.set_response([#Ok 42]);
  await* handler.trigger(1);
  await mock_ledger.set_balance(0);
  assert state() == (0, 17, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({ credited = 15; deducted = 20 }),
    #issued(2),
  ]);

  // update ledger fee
  await mock_ledger.set_fee(1);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 1; old = 3 }),
  ]);

  // withdraw from credit (fee < amount <= credit)
  // should be successful
  await mock_ledger.set_response([#Ok 42]);
  assert (await* handler.withdrawFromCredit(user1, account, 5, null)) == #ok(42, 2);
  assert handler.userCredit(user1) == 10;
  assert handler.poolCredit() == 4;
  assert state() == (0, 14, 0);
  assert journal.hasEvents([
    #burned(5),
    #issued(2),
    #withdraw({ amount = 5; to = account }),
  ]);

  // withdraw from credit (amount <= fee)
  var transfer_count = await mock_ledger.transfer_count();
  await mock_ledger.set_response([#Ok 42]); // transfer call should not be executed anyway
  assert (await* handler.withdrawFromCredit(user1, account, 3, null)) == #err(#TooLowQuantity);
  assert (await mock_ledger.transfer_count()) == transfer_count; // no transfer call
  assert handler.userCredit(user1) == 10; // not changed
  assert state() == (0, 14, 0); // state unchanged
  assert journal.hasEvents([
    #burned(3),
    #withdrawalError(#TooLowQuantity),
    #issued(3),
  ]);

  // withdraw from credit (credit < amount)
  await mock_ledger.set_response([#Err(#InsufficientFunds({ balance = 10 }))]);
  assert (await* handler.withdrawFromCredit(user1, account, 100, null)) == #err(#InsufficientCredit);
  assert state() == (0, 14, 0); // state unchanged
  assert journal.hasEvents([#withdrawalError(#InsufficientCredit)]);

  // increase fee while withdraw is being underway
  // withdraw should fail, fee should be updated
  await mock_ledger.lock_transfer("INCREASE_FEE_WITHDRAW_IS_BEING_UNDERWAY");
  let f2 = async { await* handler.withdrawFromCredit(user1, account, 5, null) };
  await mock_ledger.set_fee(2);
  await mock_ledger.set_response([#Err(#BadFee { expected_fee = 2 })]); // the second call should not be executed
  await mock_ledger.release_transfer(); // let transfer return
  assert (await f2) == #err(#BadFee { expected_fee = 4 });
  assert state() == (0, 14, 0); // state unchanged
  assert journal.hasEvents([
    #burned(5),
    #feeUpdated({ new = 2; old = 1 }),
    #withdrawalError(#BadFee { expected_fee = 4 }),
    #issued(+5),
  ]);

  // debit user
  // (for checking withdrawal from pool)
  assert handler.debitUser(user1, 10);
  assert journal.hasEvents([#debited(10)]);
  assert handler.userCredit(user1) == 0;
  assert handler.poolCredit() == 14;

  // withdraw from pool (ledger_fee < amount <= pool_credit)
  // should be successful
  await mock_ledger.set_response([#Ok 42]);
  assert (await* handler.withdrawFromPool(account, 4, null)) == #ok(42, 2);
  assert handler.poolCredit() == 10;
  assert state() == (0, 10, 0);
  assert journal.hasEvents([
    #burned(4),
    #withdraw({ amount = 4; to = account }),
  ]);

  // withdraw from pool (amount <= ledger_fee)
  transfer_count := await mock_ledger.transfer_count();
  await mock_ledger.set_response([#Ok 42]); // transfer call should not be executed anyway
  assert (await* handler.withdrawFromPool(account, 2, null)) == #err(#TooLowQuantity);
  assert (await mock_ledger.transfer_count()) == transfer_count; // no transfer call
  assert handler.poolCredit() == 10; // not changed
  assert state() == (0, 10, 0); // state unchanged
  assert journal.hasEvents([
    #burned(2),
    #withdrawalError(#TooLowQuantity),
    #issued(2),
  ]);

  // withdraw from pool (credit < amount)
  await mock_ledger.set_response([#Err(#InsufficientFunds({ balance = 10 }))]);
  assert (await* handler.withdrawFromPool(account, 100, null)) == #err(#InsufficientCredit);
  assert state() == (0, 10, 0); // state unchanged
  assert journal.hasEvents([#withdrawalError(#InsufficientCredit)]);
  
};

import Principal "mo:base/Principal";

import MockLedger "util/mock_ledger";
import Util "util/common";

let user1 = Principal.fromBlob("1");
let account = { owner = Principal.fromBlob("o"); subaccount = null };

do {
  let mock_ledger = MockLedger.MockLedger();
  let (handler, journal, state) = Util.createHandler(mock_ledger, false);

  // update fee first time
  mock_ledger.fee_.set(3);
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
  mock_ledger.balance_.set(20);
  assert (await* handler.notify(user1)) == ?(20, 15);
  assert state() == (20, 0, 1);
  assert journal.hasEvents([
    #issued(15),
    #newDeposit(20),
  ]);

  // trigger consolidation
  mock_ledger.transfer_.set(#Ok 42);
  await* handler.trigger(1);
  mock_ledger.balance_.set(0);
  assert state() == (0, 17, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({ credited = 15; deducted = 20 }),
    #issued(2),
  ]);

  // update ledger fee
  mock_ledger.fee_.set(1);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 1; old = 3 }),
  ]);

  // withdraw from credit (fee < amount <= credit)
  // should be successful
  mock_ledger.transfer_.set(#Ok 42);
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
  mock_ledger.transfer_.set(#Ok 42); // transfer call should not be executed anyway
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
  mock_ledger.transfer_.set(#Err(#InsufficientFunds({ balance = 10 })));
  assert (await* handler.withdrawFromCredit(user1, account, 100, null)) == #err(#InsufficientCredit);
  assert state() == (0, 14, 0); // state unchanged
  assert journal.hasEvents([#withdrawalError(#InsufficientCredit)]);

  // increase fee while withdraw is being underway
  // withdraw should fail, fee should be updated
  mock_ledger.transfer_.lock("INCREASE_FEE_WITHDRAW_IS_BEING_UNDERWAY");
  let f2 = async { await* handler.withdrawFromCredit(user1, account, 5, null) };
  mock_ledger.fee_.set(2);
  mock_ledger.transfer_.set(#Err(#BadFee { expected_fee = 2 })); // the second call should not be executed
  mock_ledger.transfer_.release(); // let transfer return
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
  mock_ledger.transfer_.set(#Ok 42);
  assert (await* handler.withdrawFromPool(account, 4, null)) == #ok(42, 2);
  assert handler.poolCredit() == 10;
  assert state() == (0, 10, 0);
  assert journal.hasEvents([
    #burned(4),
    #withdraw({ amount = 4; to = account }),
  ]);

  // withdraw from pool (amount <= ledger_fee)
  transfer_count := await mock_ledger.transfer_count();
  mock_ledger.transfer_.set(#Ok 42); // transfer call should not be executed anyway
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
  mock_ledger.transfer_.set(#Err(#InsufficientFunds({ balance = 10 })));
  assert (await* handler.withdrawFromPool(account, 100, null)) == #err(#InsufficientCredit);
  assert state() == (0, 10, 0); // state unchanged
  assert journal.hasEvents([#withdrawalError(#InsufficientCredit)]);
};

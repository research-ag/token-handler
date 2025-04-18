import Principal "mo:base/Principal";

import MockLedger "util/mock_ledger";
import Util "util/common";

let user1 = Principal.fromBlob("1");
let account = { owner = Principal.fromBlob("o"); subaccount = null };
let DEBUG = false;

do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "withdrawal");
  let (handler, journal, state) = Util.createHandler(mock_ledger, false);

  // update fee first time
  ignore mock_ledger.fee_.stage_unlocked(?3);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 3;
  assert journal.hasEvents([
    #feeUpdated({ new = 3; old = 0; delta = 0 }),
  ]);

  // update surcharge
  handler.setSurcharge(2);
  assert handler.surcharge() == 2;
  assert journal.hasEvents([
    #surchargeUpdated({ new = 2; old = 0 }),
  ]);

  // increase deposit again
  ignore mock_ledger.balance_.stage_unlocked(?20);
  assert (await* handler.notify(user1)) == ?(20, 15);
  assert state() == (20, 0, 1);
  assert journal.hasEvents([
    #newDeposit {creditInc = 15; depositInc = 20; ledgerFee = 3; surcharge = 2}
  ]);

  // trigger consolidation
  ignore mock_ledger.transfer_.stage_unlocked(?#Ok 42);
  await* handler.trigger(1);
  ignore mock_ledger.balance_.stage_unlocked(?0);
  assert state() == (0, 17, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({
      credited = 17;
      deducted = 20;
      fee = 3;
    }),
  ]);

  // update ledger fee
  ignore mock_ledger.fee_.stage_unlocked(?1);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 1; old = 3; delta = 0 }),
  ]);

  // withdraw from credit (fee < amount <= credit)
  // should be successful
  ignore mock_ledger.transfer_.stage_unlocked(?#Ok 42);
  assert (await* handler.withdrawFromCredit(user1, account, 5, null)) == #ok(42, 2);
  assert handler.userCredit(user1) == 10;
  assert handler.handlerCredit() == 4;
  assert state() == (0, 14, 0);
  assert journal.hasEvents([
    #locked(5),
    #withdraw({ amount = 5; surcharge = 2; withdrawn = 3; to = account }),
  ]);

  // withdraw from credit (amount <= fee)
  // We are not staging a transfer_ response.
  // By doing so we assert that no call to transfer_ will happen.
  // Because of it did then we would get a pop from queue error.
  assert (await* handler.withdrawFromCredit(user1, account, 3, null)) == #err(#TooLowQuantity);
  assert handler.userCredit(user1) == 10; // not changed
  assert state() == (0, 14, 0); // state unchanged
  assert journal.hasEvents([]);

  // withdraw from credit (credit < amount)
  // We are not staging a transfer_ response because no call will happen.
  assert (await* handler.withdrawFromCredit(user1, account, 100, null)) == #err(#InsufficientCredit);
  assert state() == (0, 14, 0); // state unchanged
  assert journal.hasEvents([]);

  // increase fee while withdraw is being underway
  // withdraw should fail, fee should be updated
  ignore mock_ledger.transfer_.stage_unlocked(?#Err(#BadFee { expected_fee = 2 })); // the second call should not be executed
  let f2 = async { await* handler.withdrawFromCredit(user1, account, 5, null) };
  assert (await f2) == #err(#BadFee { expected_fee = 4 });
  assert state() == (0, 14, 0); // state unchanged

  assert journal.hasEvents([
    #locked(5),
    #feeUpdated({ new = 2; old = 1; delta = 0 }),
    #locked(-5)
  ]);

  // debit user
  // (for checking withdrawal from pool)
  assert handler.debitUser(user1, 10);
  assert journal.hasEvents([#debited(10)]);
  assert handler.userCredit(user1) == 0;
  assert handler.poolCredit() == 10;

  // withdraw from pool (ledger_fee < amount <= pool_credit)
  // should be successful
  ignore mock_ledger.transfer_.stage_unlocked(?#Ok 42);
  assert (await* handler.withdrawFromPool(account, 4, null)) == #ok(42, 2);
  assert handler.poolCredit() == 6;
  assert state() == (0, 10, 0);
  assert journal.hasEvents([
    #locked(4),
    #withdraw({ amount = 4; to = account; surcharge = 0; withdrawn = 4 }),
  ]);

  // withdraw from pool (amount <= ledger_fee)
  // We are not staging a transfer_ response because no call will happen.
  assert (await* handler.withdrawFromPool(account, 2, null)) == #err(#TooLowQuantity);
  assert handler.poolCredit() == 6; // not changed
  assert state() == (0, 10, 0); // state unchanged
  assert journal.hasEvents([]);

  // withdraw from pool (credit < amount)
  // We are not staging a transfer_ response because no call will happen.
  assert (await* handler.withdrawFromPool(account, 100, null)) == #err(#InsufficientCredit);
  assert state() == (0, 10, 0); // state unchanged
  assert journal.hasEvents([]);

  assert not handler.isFrozen();
};

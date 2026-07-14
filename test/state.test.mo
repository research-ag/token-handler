import Principal "mo:core/Principal";

import TokenHandler "../src";
import MockLedger "util/mock_ledger";
import Util "util/common";

// Tests asserting the full `state()` record across the deposit lifecycle.

let DEBUG = false;
let user1 = Principal.fromBlob("1");
let account = { owner = Principal.fromBlob("o"); subaccount = null };

// Block A: notify + consolidation, with a non-zero ledger fee and surcharge.
do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "state A");
  let (handler, journal, _) = Util.createHandler(mock_ledger, false);

  ignore mock_ledger.fee_.stage_unlocked(?3);
  ignore await* TokenHandler.fetchFee(handler);
  handler.setSurcharge(2);
  assert journal.hasEvents([
    #feeUpdated({ new = 3; old = 0; delta = 0 }),
    #surchargeUpdated({ new = 2; old = 0 }),
  ]);

  // notify deposit of 10 (credit = 10 - fee - surcharge = 5)
  ignore mock_ledger.balance_.stage_unlocked(?10);
  assert (await* TokenHandler.notify(handler, user1)) == ?(10, 5);
  assert journal.hasEvents([
    #newDeposit({ creditInc = 5; depositInc = 10; ledgerFee = 3; surcharge = 2 }),
  ]);

  let s1 = handler.state();
  assert s1.balance.deposited == 10;
  assert s1.balance.underway == 0;
  assert s1.balance.queued == 10;
  assert s1.balance.consolidated == 0;
  assert s1.flow.consolidated == 0;
  assert s1.flow.withdrawn == 0;
  assert s1.credit.total == 7; // user credit 5 + handler pool (surcharge) 2
  assert s1.credit.pool == 2;
  assert s1.users.queued == 1;
  assert s1.users.locked == 0;
  assert s1.users.total == 1;

  // consolidate
  ignore mock_ledger.transfer_.stage_unlocked(? #Ok 0);
  await* TokenHandler.trigger(handler, 1);
  assert journal.hasEvents([
    #consolidated({ credited = 7; deducted = 10; fee = 3 }),
  ]);

  let s2 = handler.state();
  assert s2.balance.deposited == 0;
  assert s2.balance.underway == 0;
  assert s2.balance.queued == 0;
  assert s2.balance.consolidated == 7;
  assert s2.flow.consolidated == 7;
  assert s2.flow.withdrawn == 0;
  assert s2.credit.total == 7;
  assert s2.credit.pool == 2;
  assert s2.users.queued == 0;
  assert s2.users.locked == 0;
  assert s2.users.total == 1;

  assert not handler.isFrozen();
};

// Block B: withdrawal from consolidated credit updates flow/withdrawn fields.
do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "state B");
  let (handler, journal, _) = Util.createHandler(mock_ledger, false);

  // fee = 0, surcharge = 0
  ignore mock_ledger.balance_.stage_unlocked(?20);
  assert (await* TokenHandler.notify(handler, user1)) == ?(20, 20);
  assert journal.hasEvents([
    #newDeposit({ creditInc = 20; depositInc = 20; ledgerFee = 0; surcharge = 0 }),
  ]);

  ignore mock_ledger.transfer_.stage_unlocked(? #Ok 0);
  await* TokenHandler.trigger(handler, 1);
  assert journal.hasEvents([
    #consolidated({ credited = 20; deducted = 20; fee = 0 }),
  ]);

  // withdraw 5 from the user's (consolidated) credit
  ignore mock_ledger.transfer_.stage_unlocked(? #Ok 1);
  assert (await* TokenHandler.withdrawFromCredit(handler, user1, account, 5, null)) == #ok(1, 5);
  assert journal.hasEvents([
    #locked(5),
    #withdraw({ amount = 5; withdrawn = 5; surcharge = 0; to = account }),
  ]);

  let s = handler.state();
  assert s.balance.deposited == 0;
  assert s.balance.underway == 0;
  assert s.balance.queued == 0;
  assert s.balance.consolidated == 15; // totalConsolidated 20 - totalWithdrawn 5
  assert s.flow.consolidated == 20;
  assert s.flow.withdrawn == 5;
  assert s.credit.total == 15;
  assert s.credit.pool == 0;
  assert s.users.queued == 0;
  assert s.users.locked == 0;
  assert s.users.total == 1;

  assert not handler.isFrozen();
};

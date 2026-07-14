import Principal "mo:core/Principal";

import TokenHandler "../src";
import MockLedger "util/mock_ledger";
import Util "util/common";

// Tests for share / unshare (stable serialization) round-tripping.

let DEBUG = false;
let user1 = Principal.fromBlob("1");
let user2 = Principal.fromBlob("2");

do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "serialization src");
  let (handler, journal, _) = Util.createHandler(mock_ledger, false);

  // Build up some non-trivial state.
  ignore mock_ledger.fee_.stage_unlocked(?3);
  ignore await* TokenHandler.fetchFee(handler);
  handler.setSurcharge(2);
  assert journal.hasEvents([
    #feeUpdated({ new = 3; old = 0; delta = 0 }),
    #surchargeUpdated({ new = 2; old = 0 }),
  ]);

  ignore mock_ledger.balance_.stage_unlocked(?10);
  assert (await* TokenHandler.notify(handler, user1)) == ?(10, 5);
  ignore mock_ledger.balance_.stage_unlocked(?20);
  assert (await* TokenHandler.notify(handler, user2)) == ?(20, 15);
  assert journal.hasEvents([
    #newDeposit({ creditInc = 5; depositInc = 10; ledgerFee = 3; surcharge = 2 }),
    #newDeposit({ creditInc = 15; depositInc = 20; ledgerFee = 3; surcharge = 2 }),
  ]);

  // Consolidate the largest deposit (user2).
  ignore mock_ledger.transfer_.stage_unlocked(? #Ok 0);
  await* TokenHandler.trigger(handler, 1);
  assert journal.hasEvents([
    #consolidated({ credited = 17; deducted = 20; fee = 3 }),
  ]);

  // Serialize and restore into a fresh handler.
  let dump = TokenHandler.share(handler);

  let mock_ledger2 = MockLedger.MockLedger(DEBUG, "serialization dst");
  let journal2 = Util.createHandler(mock_ledger2, false);
  let handler2 = journal2.0;
  TokenHandler.unshare(handler2, dump);

  // The restored handler must expose the exact same public state.
  assert handler2.state() == handler.state();
  assert handler2.ledgerFee() == handler.ledgerFee();
  assert handler2.surcharge() == handler.surcharge();
  assert handler2.userCredit(user1) == handler.userCredit(user1);
  assert handler2.userCredit(user2) == handler.userCredit(user2);
  assert handler2.poolCredit() == handler.poolCredit();
  assert handler2.handlerCredit() == handler.handlerCredit();
  assert handler2.isFrozen() == handler.isFrozen();
  assert handler2.notificationsOnPause() == handler.notificationsOnPause();

  // Sanity: concrete expected values.
  assert handler2.ledgerFee() == 3;
  assert handler2.surcharge() == 2;
  assert handler2.userCredit(user1) == 5;
  assert handler2.userCredit(user2) == 15;
  assert handler2.state().flow.consolidated == 17;
  assert handler2.state().balance.deposited == 10;

  assert not handler.isFrozen();
  assert not handler2.isFrozen();
};

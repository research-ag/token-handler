import Principal "mo:base/Principal";

import MockLedger "util/mock_ledger";
import Util "util/common";

let DEBUG = false;
let user1 = Principal.fromBlob("1");

do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "");
  let (handler, journal, state) = Util.createHandler(mock_ledger, false);

  // update fee first time
  ignore mock_ledger.fee_.stage_unlocked(?2);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 2;
  assert journal.hasEvents([
    #feeUpdated({ new = 2; old = 0; delta = 0 }),
  ]);

  // update surcharge
  handler.setSurcharge(2);
  assert handler.surcharge() == 2;
  assert journal.hasEvents([
    #surchargeUpdated({ new = 2; old = 0 }),
  ]);

  // Change fee while notify is underway with locked 0-deposit.
  // 0-deposits can be temporarily being stored in deposit registry because of being locked with #notify.
  // Deposit registry recalculation is triggered and credits related to 0-deposits should not be corrected there.

  // scenario 1: increase fee
  let i = mock_ledger.balance_.stage(?5);
  ignore mock_ledger.fee_.stage_unlocked(?4);
  let f1 = async { await* handler.notify(user1) };
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 4; old = 2; delta = 0 }),
  ]);
  mock_ledger.balance_.release(i); // let notify return
  assert (await f1) == ?(0, 0);
  assert state() == (0, 0, 0); // state unchanged because deposit has not changed
  assert handler.userCredit(user1) == 0; // credit should not be corrected
  assert journal.hasEvents([]);

  // scenario 2: decrease fee
  let i2 = mock_ledger.balance_.stage(?5);
  ignore mock_ledger.fee_.stage_unlocked(?2);
  let f2 = async { await* handler.notify(user1) };
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 2; old = 4; delta = 0 }),
  ]);
  mock_ledger.balance_.release(i2); // let notify return
  assert (await f2) == ?(5, 1);
  assert state() == (5, 0, 1); // state unchanged because deposit has not changed
  assert handler.userCredit(user1) == 1; // credit should not be corrected
  assert journal.hasEvents([
    #newDeposit({ creditInc = 1; depositInc = 5; ledgerFee = 2; surcharge = 2 })
  ]);

  // Don't recalculate credits related to deposits when fee changes

  // scenario 1: new_fee < prev_fee < deposit
  ignore mock_ledger.fee_.stage_unlocked(?1);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 1; old = 2; delta = -1 }),
  ]);
  assert handler.userCredit(user1) == 1; // credit not corrected

  // scenario 2: prev_fee < new_fee < deposit
  ignore mock_ledger.fee_.stage_unlocked(?2);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 2; old = 1; delta = 1 }),
  ]);
  assert handler.userCredit(user1) == 1; // credit not corrected

  // scenario 3: prev_fee < deposit <= new_fee
  ignore mock_ledger.fee_.stage_unlocked(?5);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 2; delta = 3 }),
  ]);
  assert handler.userCredit(user1) == 1; // credit not corrected

  assert not handler.isFrozen();
};

do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "");
  let (handler, journal, _) = Util.createHandler(mock_ledger, false);

  // update fee first time
  ignore mock_ledger.fee_.stage_unlocked(?5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0; delta = 0 }),
  ]);

  // fetching fee should not overlap
  let i = mock_ledger.fee_.stage(?6);
  let f1 = async { await* handler.fetchFee() };
  let f2 = async { await* handler.fetchFee() };
  assert (await f2) == null;
  mock_ledger.fee_.release(i);
  assert (await f1) == ?6;
  assert journal.hasEvents([
    #feeUpdated({ new = 6; old = 5; delta = 0 }),
  ]);
  assert not handler.isFrozen();
};

do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "");
  let (handler, journal, _) = Util.createHandler(mock_ledger, false);

  handler.setSurcharge(15);
  assert handler.surcharge() == 15;
  assert journal.hasEvents([
    #surchargeUpdated({ new = 15; old = 0 })
  ]);

  ignore mock_ledger.balance_.stage_unlocked(?16);
  assert (await* handler.notify(user1)) == ?(16, 1);
  assert journal.hasEvents([
    #newDeposit({ creditInc = 1; depositInc = 16; ledgerFee = 0; surcharge = 15 }),
  ]);

  let i = mock_ledger.transfer_.stage_unlocked(?(#Ok 0));
  await* handler.trigger(1);
  assert mock_ledger.transfer_.state(i) == #responded;
  assert journal.hasEvents([
    #consolidated({ credited = 16; deducted = 16; fee = 0 }),
  ]);

  assert handler.handlerCredit() == 15;
  assert handler.poolCredit() == 0;

  // credit user
  // case: pool credit < amount
  assert handler.creditUser(user1, 30) == false;
  assert journal.hasEvents([]);
  assert handler.poolCredit() == 0;
  assert handler.userCredit(user1) == 1;

  // debit user
  // case: credit < amount
  assert handler.debitUser(user1, 30) == false;
  assert journal.hasEvents([]);
  assert handler.poolCredit() == 0;
  assert handler.userCredit(user1) == 1;

  // debit user
  // case: credit >= amount
  assert handler.debitUser(user1, 1) == true;
  assert journal.hasEvents([#debited(1)]);
  assert handler.poolCredit() == 1;
  assert handler.userCredit(user1) == 0;

  // credit user
  // case: pool credit <= amount
  assert (handler.creditUser(user1, 1)) == true;
  assert journal.hasEvents([#credited(1)]);
  assert handler.poolCredit() == 0;
  assert handler.userCredit(user1) == 1;

  assert not handler.isFrozen();
};

do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "");
  let (handler, journal, _) = Util.createHandler(mock_ledger, false);

  // update fee first time
  ignore mock_ledger.fee_.stage_unlocked(?2);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 2;
  assert journal.hasEvents([
    #feeUpdated({ new = 2; old = 0; delta = 0 }),
  ]);

  // update surcharge
  handler.setSurcharge(3);
  assert handler.surcharge() == 3;
  assert journal.hasEvents([
    #surchargeUpdated({ new = 3; old = 0 }),
  ]);

  assert handler.fee(#deposit) == 5;
  assert handler.fee(#allowance) == 5;
  assert handler.fee(#withdrawal) == 5;

  // update surcharge
  handler.setSurcharge(5);
  assert handler.surcharge() == 5;
  assert journal.hasEvents([
    #surchargeUpdated({ new = 5; old = 3 }),
  ]);

  assert handler.fee(#deposit) == 7;
  assert handler.fee(#allowance) == 7;
  assert handler.fee(#withdrawal) == 7;
};

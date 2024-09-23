import Principal "mo:base/Principal";

import MockLedger "util/mock_ledger";
import Util "util/common";

let user1 = Principal.fromBlob("1");
let verbose = false;

do {
  let mock_ledger = MockLedger.MockLedger();
  let (handler, journal, state) = Util.createHandler(mock_ledger, false, verbose);

  // update fee first time
  mock_ledger.fee_.set(2);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 2;
  assert journal.hasEvents([
    #feeUpdated({ new = 2; old = 0 }),
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
  mock_ledger.balance_.lock("CHANGE_FEE_WHILE_NOTIFY_IS_UNDERWAY_WITH_LOCKED_0_DEPOSIT_SCENARIO_1");
  mock_ledger.balance_.set(5);
  let f1 = async { await* handler.notify(user1) };
  mock_ledger.fee_.set(4);
  ignore await* handler.fetchFee();
  
  assert journal.hasEvents([
    #feeUpdated({ new = 4; old = 2 }),
  ]);
  mock_ledger.balance_.release(); // let notify return
  assert (await f1) == ?(0, 0);
  assert state() == (0, 0, 0); // state unchanged because deposit has not changed
  assert handler.userCredit(user1) == 0; // credit should not be corrected
  assert journal.hasEvents([]);

  // scenario 2: decrease fee
  mock_ledger.balance_.lock("CHANGE_FEE_WHILE_NOTIFY_IS_UNDERWAY_WITH_LOCKED_0_DEPOSIT_SCENARIO_2");
  mock_ledger.balance_.set(5);
  let f2 = async { await* handler.notify(user1) };
  mock_ledger.fee_.set(2);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 2; old = 4 }),
  ]);
  mock_ledger.balance_.release(); // let notify return
  assert (await f2) == ?(5, 1);
  assert state() == (5, 0, 1); // state unchanged because deposit has not changed
  assert handler.userCredit(user1) == 1; // credit should not be corrected
  assert journal.hasEvents([
    #issued(+1),
    #newDeposit(5),
  ]);

  // Recalculate credits related to deposits when fee changes

  // scenario 1: new_fee < prev_fee < deposit
  mock_ledger.fee_.set(1);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #issued(+1),
    #feeUpdated({ new = 1; old = 2 }),
  ]);
  assert handler.userCredit(user1) == 2; // credit corrected

  // scenario 2: prev_fee < new_fee < deposit
  mock_ledger.fee_.set(2);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #issued(-1),
    #feeUpdated({ new = 2; old = 1 }),
  ]);
  assert handler.userCredit(user1) == 1; // credit corrected

  // scenario 3: prev_fee < deposit <= new_fee
  mock_ledger.fee_.set(5);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #issued(-1),
    #feeUpdated({ new = 5; old = 2 }),
  ]);
  assert handler.userCredit(user1) == 0; // credit corrected

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  let mock_ledger = MockLedger.MockLedger();
  let (handler, journal, _) = Util.createHandler(mock_ledger, false, verbose);

  // update fee first time
  mock_ledger.fee_.set(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
  ]);

  // fetching fee should not overlap
  mock_ledger.fee_.lock("FETCHING_FEE_SHOULD_NOT_OVERLAP");
  mock_ledger.fee_.set(6);
  let f1 = async { await* handler.fetchFee() };
  let f2 = async { await* handler.fetchFee() };
  assert (await f2) == null;
  mock_ledger.fee_.release();
  assert (await f1) == ?6;
  assert journal.hasEvents([
    #feeUpdated({ new = 6; old = 5 }),
  ]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  let mock_ledger = MockLedger.MockLedger();
  let (handler, journal, _) = Util.createHandler(mock_ledger, false, verbose);

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
  let mock_ledger = MockLedger.MockLedger();
  let (handler, journal, state) = Util.createHandler(mock_ledger, false, verbose);

  // update fee first time
  mock_ledger.fee_.set(2);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 2;
  assert journal.hasEvents([
    #feeUpdated({ new = 2; old = 0 }),
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


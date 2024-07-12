import Principal "mo:base/Principal";

import Util "util/common";
import MockLedger "util/mock_ledger";

let user1 = Principal.fromBlob("1");

// Basic tests
do {
  let mock_ledger = await MockLedger.MockLedger();
  let (handler, journal, state) = Util.createHandler(mock_ledger, false);

  // init state
  assert handler.ledgerFee() == 0;
  assert journal.hasEvents([]);

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

  // fee = ledger_fee + surcharge

  // notify with 0 balance
  await mock_ledger.set_balance(0);
  assert (await* handler.notify(user1)) == ?(0, 0);
  assert state() == (0, 0, 0);
  assert journal.hasEvents([]);

  // notify with balance <= fee
  await mock_ledger.set_balance(5);
  assert (await* handler.notify(user1)) == ?(0, 0);
  assert state() == (0, 0, 0);
  assert journal.hasEvents([]);

  // notify with balance > fee
  await mock_ledger.set_balance(6);
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state() == (6, 0, 1);
  assert journal.hasEvents([#issued(1), #newDeposit(6)]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

// Race condition tests
do {
  let mock_ledger = await MockLedger.MockLedger();
  let (handler, journal, state) = Util.createHandler(mock_ledger, false);

  // update fee first time
  await mock_ledger.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
  ]);

  // notify with balance > fee
  await mock_ledger.set_balance(6);
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state() == (6, 0, 1);
  assert journal.hasEvents([#issued(1), #newDeposit(6)]);

  // increase fee while item still in queue (trigger did not run yet)
  await mock_ledger.set_fee(6);
  ignore await* handler.fetchFee();
  assert state() == (0, 0, 0); // recalculation after fee update
  assert journal.hasEvents([
    #issued(-1),
    #feeUpdated({ new = 6; old = 5 }),
  ]);

  // increase deposit again
  await mock_ledger.set_balance(7);
  assert (await* handler.notify(user1)) == ?(7, 1);
  assert state() == (7, 0, 1);
  assert journal.hasEvents([
    #issued(1),
    #newDeposit(7),
  ]);

  // increase fee while notify is underway (and item still in queue)
  // scenario 1: old_fee < previous = latest <= new_fee
  // this means no new deposit has happened (latest = previous)
  await mock_ledger.lock_balance("INCREASE_FEE_WHILE_NOTIFY_IS_UNDERWAY_SCENARIO_1");
  let f1 = async { await* handler.notify(user1) };
  await mock_ledger.set_fee(10); // fee 6 -> 10
  assert state() == (7, 0, 1); // state from before
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #issued(-1),
    #feeUpdated({ new = 10; old = 6 }),
  ]);
  assert state() == (0, 0, 0); // state changed
  await mock_ledger.release_balance(); // let notify return
  assert (await f1) == ?(0, 0); // deposit <= new_fee
  assert journal.hasEvents([]);

  // increase deposit again
  await mock_ledger.set_balance(15);
  assert (await* handler.notify(user1)) == ?(15, 5);
  assert state() == (15, 0, 1);
  assert journal.hasEvents([
    #issued(5),
    #newDeposit(15),
  ]);

  // increase fee while notify is underway (and item still in queue)
  // scenario 2: old_fee < previous <= new_fee < latest
  await mock_ledger.set_balance(20);
  await mock_ledger.lock_balance("INCREASE_FEE_WHILE_NOTIFY_IS_UNDERWAY_SCENARIO_2");
  let f2 = async { await* handler.notify(user1) }; // would return ?(5, _) at old fee
  await mock_ledger.set_fee(15); // fee 10 -> 15
  assert state() == (15, 0, 1); // state from before
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #issued(-5),
    #feeUpdated({ new = 15; old = 10 }),
  ]);
  assert state() == (0, 0, 0); // state changed
  await mock_ledger.release_balance(); // let notify return
  assert (await f2) == ?(20, 5); // credit = latest - new_fee
  assert state() == (20, 0, 1); // state should have changed
  assert journal.hasEvents([
    #issued(5),
    #newDeposit(20),
  ]);

  // decrease fee while notify is underway (and item still in queue)
  // new_fee < old_fee < previous == latest
  await mock_ledger.lock_balance("DECREASE_FEE_WHILE_NOTIFY_IS_UNDERWAY");
  let f3 = async { await* handler.notify(user1) };
  await mock_ledger.set_fee(10); // fee 15 -> 10
  assert state() == (20, 0, 1); // state from before
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #issued(+5),
    #feeUpdated({ new = 10; old = 15 }),
  ]);
  assert state() == (20, 0, 1); // state unchanged
  await mock_ledger.release_balance(); // let notify return
  assert (await f3) == ?(0, 0);
  assert handler.userCredit(user1) == 10; // credit increased
  assert state() == (20, 0, 1); // state unchanged

  // call multiple notify() simultaneously
  // only the first should return state, the rest should not be executed
  await mock_ledger.lock_balance("CALL_MULTIPLE_NOTIFY_SIMULTANEOUSLY");
  let fut1 = async { await* handler.notify(user1) };
  let fut2 = async { await* handler.notify(user1) };
  let fut3 = async { await* handler.notify(user1) };
  assert (await fut2) == null; // should return null
  assert (await fut3) == null; // should return null
  await mock_ledger.release_balance(); // let notify return
  assert (await fut1) == ?(0, 0); // first notify() should return state
  assert handler.userCredit(user1) == 10; // credit unchanged
  assert state() == (20, 0, 1); // state unchanged because deposit has not changed
  assert journal.hasEvents([]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

// Test credit inc from notify
do {
  let mock_ledger = await MockLedger.MockLedger();
  let (handler, journal, state) = Util.createHandler(mock_ledger, false);

  // update fee first time
  await mock_ledger.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.ledgerFee() == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
  ]);

  // notify 1
  await mock_ledger.set_balance(7);
  assert (await* handler.notify(user1)) == ?(7, 2);
  assert handler.userCredit(user1) == 2;
  assert state() == (7, 0, 1);
  assert journal.hasEvents([
    #issued(2),
    #newDeposit(7),
  ]);

  // notify 2
  await mock_ledger.set_balance(17);
  assert (await* handler.notify(user1)) == ?(10, 10);
  assert handler.userCredit(user1) == 12;
  assert state() == (17, 0, 1);
  assert journal.hasEvents([
    #issued(10),
    #newDeposit(10),
  ]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

// Test notifications pause
do {
  let mock_ledger = await MockLedger.MockLedger();
  let (handler, journal, state) = Util.createHandler(mock_ledger, false);

  // notify with 0 balance
  await mock_ledger.set_balance(0);
  assert (await* handler.notify(user1)) == ?(0, 0);

  // initial state
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

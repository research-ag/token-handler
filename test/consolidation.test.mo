import Principal "mo:base/Principal";

import Util "util/common";
import MockLedger "util/mock_ledger";

let user1 = Principal.fromBlob("1");
let user2 = Principal.fromBlob("2");
let user3 = Principal.fromBlob("3");

do {
  let mock_ledger = await MockLedger.MockLedger();
  let (handler, journal, state) = Util.createHandler(mock_ledger, false);

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

  // increase fee while deposit is being consolidated (implicitly)
  // scenario 1: old_ledger_fee < deposit <= new_ledger_fee
  // consolidation should fail and deposit should be reset
  await mock_ledger.set_balance(10);
  assert (await* handler.notify(user1)) == ?(10, 5);
  assert journal.hasEvents([
    #issued(5),
    #newDeposit(10),
  ]);
  assert state() == (10, 0, 1);
  await mock_ledger.lock_transfer("IMP_INCREASE_FEE_WHILE_DEPOSIT_IS_BEING_CONSOLIDATED_SCENARIO_1");
  let f1 = async { await* handler.trigger(1) };
  await mock_ledger.set_fee(10);
  await mock_ledger.set_response([#Err(#BadFee { expected_fee = 10 })]);
  await mock_ledger.release_transfer(); // let transfer return
  await f1;
  assert handler.userCredit(user1) == 0; // credit has been corrected after consolidation
  assert state() == (0, 0, 0); // consolidation failed with deposit reset
  assert journal.hasEvents([
    #feeUpdated({ new = 10; old = 3 }),
    #consolidationError(#BadFee({ expected_fee = 10 })),
    #issued(-5),
  ]);

  // increase fee while deposit is being consolidated (implicitly)
  // scenario 2: old_ledger_fee < new_ledger_fee < deposit
  // consolidation should fail and credit should be adjusted with new fee
  await mock_ledger.set_balance(20);
  assert (await* handler.notify(user1)) == ?(20, 8);
  assert journal.hasEvents([
    #issued(+8),
    #newDeposit(20),
  ]);
  assert state() == (20, 0, 1);
  await mock_ledger.lock_transfer("IMP_INCREASE_FEE_WHILE_DEPOSIT_IS_BEING_CONSOLIDATED_SCENARIO_2");
  let f2 = async { await* handler.trigger(1) };
  await mock_ledger.set_fee(15);
  await mock_ledger.set_response([#Err(#BadFee { expected_fee = 15 })]);
  await mock_ledger.release_transfer(); // let transfer return
  await f2;
  assert handler.userCredit(user1) == 3; // credit has been corrected after consolidation
  assert state() == (20, 0, 1); // consolidation failed with updated deposit scheduled
  assert journal.hasEvents([
    #feeUpdated({ new = 15; old = 10 }),
    #consolidationError(#BadFee({ expected_fee = 15 })),
    #issued(-8),
    #issued(+3),
  ]);

  // increase fee while deposit is being consolidated (explicitly)
  // scenario 1: old_ledger_fee < deposit <= new_ledger_fee
  // consolidation should fail and credit should be reset
  assert handler.userCredit(user1) == 3; // initial credit
  assert journal.hasEvents([]);
  assert state() == (20, 0, 1);
  await mock_ledger.lock_transfer("EXP_INCREASE_FEE_WHILE_DEPOSIT_IS_BEING_CONSOLIDATED_SCENARIO_1");
  let f3 = async { await* handler.trigger(1) };
  await mock_ledger.set_fee(100);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 100; old = 15 })
  ]);
  await mock_ledger.set_response([#Err(#BadFee { expected_fee = 100 })]);
  await mock_ledger.release_transfer(); // let transfer return
  await f3;
  assert handler.userCredit(user1) == 0; // credit has been corrected
  assert state() == (0, 0, 0); // consolidation failed with deposit reset
  assert journal.hasEvents([
    #consolidationError(#BadFee({ expected_fee = 100 })),
    #issued(-3),
  ]);

  // increase fee while deposit is being consolidated (explicitly)
  // scenario 2: old_fee < new_fee < deposit
  // consolidation should fail and deposit should be adjusted with new fee
  await mock_ledger.set_fee(5);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 100 })
  ]);
  assert (await* handler.notify(user1)) == ?(20, 13);
  assert journal.hasEvents([
    #issued(13),
    #newDeposit(20),
  ]);
  assert state() == (20, 0, 1);
  await mock_ledger.lock_transfer("EXP_INCREASE_FEE_WHILE_DEPOSIT_IS_BEING_CONSOLIDATED_SCENARIO_2");
  let f4 = async { await* handler.trigger(1) };
  await mock_ledger.set_fee(6);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 6; old = 5 }),
  ]);
  await mock_ledger.set_response([#Err(#BadFee { expected_fee = 6 })]);
  await mock_ledger.release_transfer(); // let transfer return
  await f4;
  assert state() == (20, 0, 1); // consolidation failed with updated deposit scheduled
  assert handler.userCredit(user1) == 12; // credit has been corrected
  assert journal.hasEvents([
    #consolidationError(#BadFee({ expected_fee = 6 })),
    #issued(-13),
    #issued(12),
  ]);

  // only 1 consolidation process can be triggered for same user at same time
  // consolidation with deposit > fee should be successful
  await mock_ledger.set_response([#Ok 42]);
  var transfer_count = await mock_ledger.transfer_count();
  let f5 = async { await* handler.trigger(1) };
  let f6 = async { await* handler.trigger(1) };
  await f5;
  await f6;
  await mock_ledger.set_balance(0);
  assert ((await mock_ledger.transfer_count())) == transfer_count + 1; // only 1 transfer call has been made
  assert handler.userCredit(user1) == 12; // credit unchanged
  assert state() == (0, 14, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({ credited = 12; deducted = 20 }),
    #issued(+2), // credit pool
  ]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

// Check whether the consolidation planned after the notification is successful
do {
  let mock_ledger = await MockLedger.MockLedger();
  let (handler, journal, state) = Util.createHandler(mock_ledger, true);

  // update fee first time
  await mock_ledger.set_fee(5);
  ignore await* handler.fetchFee();
  assert handler.fee(#deposit) == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
  ]);

  // update surcharge
  handler.setSurcharge(2);
  assert handler.surcharge() == 2;
  assert journal.hasEvents([
    #surchargeUpdated({ new = 2; old = 0 }),
  ]);

  // notify with balance > fee
  await mock_ledger.set_balance(8);
  assert (await* handler.notify(user1)) == ?(8, 1);
  assert state() == (8, 0, 1);
  assert journal.hasEvents([
    #issued(+1),
    #newDeposit(8),
  ]);

  // wait for consolidation
  await async {};
  await async {};

  assert state() == (0, 3, 0); // consolidation successful
  journal.debugShow(0);
  assert journal.hasEvents([
    #consolidated({ credited = 1; deducted = 8 }),
    #issued(+2), // credit pool
  ]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

do {
  // fresh handler
  let (handler, journal, state, ledger) = Util.createHandlerV2(false);
  // stage a response
  let (release, status) = ledger.fee_.stage(?5);
  // trigger call
  let fut1 = async { await* handler.fetchFee() };
  // wait for call to arrive
  while (status() == #staged) await async {};
  // trigger second call
  assert (await* handler.fetchFee()) == null;
  // release response
  release();
  assert (await fut1) == ?5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
  ]);

  // stage a response and release it immediately
  ledger.balance_.stage(?20).0 ();
  assert (await* handler.notify(user1)) == ?(20, 15); // (deposit, credit)
  assert journal.hasEvents([
    #issued(+15),
    #newDeposit(20),
  ]);
  assert state() == (20, 0, 1);
  ledger.transfer_.stage(null).0 (); // error response
  await* handler.trigger(1);
  assert journal.hasEvents([
    #consolidationError(#CallIcrc1LedgerError),
    #issued(-15),
    #issued(+15),
  ]);
  assert state() == (20, 0, 1);
  ledger.transfer_.stage(?(#Ok 0)).0 ();
  await* handler.trigger(1);
  assert journal.hasEvents([
    #consolidated({ credited = 15; deducted = 20 }),
    #issued(+0), // credit to pool (0)
  ]);
  assert state() == (0, 15, 0);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

// Multiple consolidations trigger
do {
  let (handler, journal, state, ledger) = Util.createHandlerV2(false);

  // update fee first time
  ledger.fee_.stage(?5).0 ();
  ignore await* handler.fetchFee();
  assert handler.fee(#deposit) == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
  ]);

  // user1 notify with balance > fee
  ledger.balance_.stage(?6).0 ();
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state() == (6, 0, 1);
  assert journal.hasEvents([
    #issued(+1),
    #newDeposit(6),
  ]);

  // user2 notify with balance > fee
  ledger.balance_.stage(?10).0 ();
  assert (await* handler.notify(user2)) == ?(10, 5);
  assert state() == (16, 0, 2);
  assert journal.hasEvents([
    #issued(+5),
    #newDeposit(10),
  ]);

  // trigger only 1 consolidation
  do {
    let (release, status) = ledger.transfer_.stage(?(#Ok 0));
    release();
    await* handler.trigger(1);
    assert status() == #ready;
    assert state() == (10, 1, 1); // user1 funds consolidated
    assert journal.hasEvents([
      #consolidated({ credited = 1; deducted = 6 }),
      #issued(0),
    ]);
  };

  // user1 notify again
  ledger.balance_.stage(?6).0 ();
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state() == (16, 1, 2);
  assert journal.hasEvents([
    #issued(+1),
    #newDeposit(6),
  ]);

  // trigger consolidation of all the deposits
  // n >= deposit_number
  do {
    let (release1, status1) = ledger.transfer_.stage(?(#Ok 0));
    let (release2, status2) = ledger.transfer_.stage(?(#Ok 0));
    ignore (release1(), release2());
    await* handler.trigger(10);
    assert (status1(), status2()) == (#ready, #ready);
    assert state() == (0, 7, 0); // all deposits consolidated
    assert journal.hasEvents([
      #consolidated({ credited = 1; deducted = 6 }),
      #issued(0),
      #consolidated({ credited = 5; deducted = 10 }),
      #issued(0),
    ]);
  };

  // user1 notify again
  ledger.balance_.stage(?6).0 ();
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state() == (6, 7, 1);
  assert journal.hasEvents([
    #issued(+1),
    #newDeposit(6),
  ]);

  // user2 notify again
  ledger.balance_.stage(?10).0 ();
  assert (await* handler.notify(user2)) == ?(10, 5);
  assert state() == (16, 7, 2);
  assert journal.hasEvents([
    #issued(+5),
    #newDeposit(10),
  ]);

  // user3 notify with balance > fee
  ledger.balance_.stage(?8).0 ();
  assert (await* handler.notify(user3)) == ?(8, 3);
  assert state() == (24, 7, 3);
  assert journal.hasEvents([
    #issued(+3),
    #newDeposit(8),
  ]);

  // trigger consolidation of all the deposits (n >= deposit_number)
  // with error calling the ledger on the 2nd deposit
  // so the consolidation loop must be stopped after attempting to consolidate the 2nd deposit
  do {
    let (release1, status1) = ledger.transfer_.stage(?(#Ok 0));
    let (release2, status2) = ledger.transfer_.stage(null);
    let (release3, status3) = ledger.transfer_.stage(?(#Ok 0));
    ignore (release1(), release2(), release3());
    await* handler.trigger(10);
    assert (status1(), status2(), status3()) == (#ready, #ready, #staged);
    assert state() == (18, 8, 2); // only user1 deposit consolidated
    assert journal.hasEvents([
      #consolidated({ credited = 1; deducted = 6 }),
      #issued(0),
      #consolidationError(#CallIcrc1LedgerError),
      #issued(-5),
      #issued(+5),
    ]);
  };

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

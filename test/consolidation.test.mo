import Principal "mo:base/Principal";
import Util "util/common";
import MockLedger "util/mock_ledger";

let DEBUG = false;
let user1 = Principal.fromBlob("1");
let user2 = Principal.fromBlob("2");
let user3 = Principal.fromBlob("3");

// Tests with triggerOnNotifications off
do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "triggerOnNotifications off");
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

  // increase fee while deposit is being consolidated (implicitly)
  // scenario 1: old_ledger_fee < deposit <= new_ledger_fee
  // consolidation should fail
  ignore mock_ledger.balance_.stage_unlocked(?10);
  assert (await* handler.notify(user1)) == ?(10, 5);
  assert journal.hasEvents([
    #newDeposit { creditInc = 5; depositInc = 10; ledgerFee = 3; surcharge = 2 },
  ]);
  assert state() == (10, 0, 1);
  ignore mock_ledger.transfer_.stage_unlocked(? #Err(#BadFee { expected_fee = 10 }));
  await* handler.trigger(1);
  assert handler.userCredit(user1) == 5; // credit has not been corrected after consolidation
  assert state() == (10, 0, 1);
  assert journal.hasEvents([
    #feeUpdated({ new = 10; old = 3; delta = 7 }),
  ]);

  // increase fee while deposit is being consolidated (implicitly)
  // scenario 2: old_ledger_fee < new_ledger_fee < deposit
  // consolidation should fail
  ignore mock_ledger.balance_.stage_unlocked(?20);
  assert (await* handler.notify(user1)) == ?(10, 10);
  assert journal.hasEvents([
    #depositInc(10),
  ]);
  assert state() == (20, 0, 1);
  ignore mock_ledger.transfer_.stage_unlocked(? #Err(#BadFee { expected_fee = 15 }));
  await* handler.trigger(1);
  assert handler.userCredit(user1) == 15; // credit has not been corrected after consolidation
  assert state() == (20, 0, 1); // consolidation failed without updated deposit
  assert journal.hasEvents([
    #feeUpdated({ new = 15; old = 10; delta = 5 }),
  ]);

  // increase fee while deposit is being consolidated (explicitly)
  // scenario 1: old_ledger_fee < deposit <= new_ledger_fee
  // consolidation should fail and credit should be reset

  assert handler.debitUser(user1, 12);
  assert journal.hasEvents([
    #debited(12)
  ]);

  assert handler.userCredit(user1) == 3; // initial credit
  assert journal.hasEvents([]);
  assert state() == (20, 0, 1);
  ignore mock_ledger.transfer_.stage_unlocked(? #Err(#BadFee { expected_fee = 100 }));
  ignore mock_ledger.fee_.stage_unlocked(?100);
  let f1 = async { await* handler.trigger(1) };
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 100; old = 15; delta = 85 }),
  ]);
  await f1;
  assert handler.userCredit(user1) == 3; // credit has not been corrected
  assert state() == (20, 0, 1); // consolidation failed without deposit reset
  assert journal.hasEvents([]);

  // increase fee while deposit is being consolidated (explicitly)
  // scenario 2: old_fee < new_fee < deposit
  // consolidation should fail and deposit should be adjusted with new fee
  ignore mock_ledger.fee_.stage_unlocked(?5);
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 100; delta = -95 }),
  ]);

  assert state() == (20, 0, 1);
  ignore mock_ledger.transfer_.stage_unlocked(? #Err(#BadFee { expected_fee = 6 }));
  ignore mock_ledger.fee_.stage_unlocked(?6);
  let f2 = async { await* handler.trigger(1) };
  ignore await* handler.fetchFee();
  assert journal.hasEvents([
    #feeUpdated({ new = 6; old = 5; delta = 1 }),
  ]);
  await f2;
  assert state() == (20, 0, 1); // consolidation failed with updated deposit scheduled
  assert handler.userCredit(user1) == 3; // credit has not been corrected
  assert journal.hasEvents([]);

  // only 1 consolidation process can be triggered for same user at same time
  // consolidation with deposit > fee should be successful
  //
  // We are only staging one transfer response, despite two trigger calls below.
  // We are thereby asserting that only the first trigger call will call transfer().
  ignore mock_ledger.transfer_.stage_unlocked(? #Ok 42);
  let f3 = async { await* handler.trigger(1) };
  let f4 = async { await* handler.trigger(1) };
  await f3;
  await f4;
  assert handler.userCredit(user1) == 3; // credit unchanged
  assert state() == (0, 14, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({ credited = 14; deducted = 20; fee = 6 }),
  ]);

  assert not handler.isFrozen();
};

// Tests with triggerOnNotifications on
// Check whether the consolidation planned after the notification is successful
do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "triggerOnNotifications on");
  let (handler, journal, state) = Util.createHandler(mock_ledger, true);

  // update fee first time
  ignore mock_ledger.fee_.stage_unlocked(?5);
  ignore await* handler.fetchFee();
  assert handler.fee(#deposit) == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0; delta = 0 }),
  ]);

  // update surcharge
  handler.setSurcharge(2);
  assert handler.surcharge() == 2;
  assert journal.hasEvents([
    #surchargeUpdated({ new = 2; old = 0 }),
  ]);

  // notify with balance > fee
  ignore mock_ledger.balance_.stage_unlocked(?8);
  // TODO try with null
  let i = mock_ledger.transfer_.stage_unlocked(? #Ok 42);
  assert (await* handler.notify(user1)) == ?(8, 1);
  assert state() == (8, 0, 1);
  assert journal.hasEvents([
    #newDeposit({ creditInc = 1; depositInc = 8; ledgerFee = 5; surcharge = 2 }),
  ]);

  // Wait for consolidation
  // Wait for transfer() response to be ready
  await* mock_ledger.transfer_.wait(i, #responded);

  assert state() == (0, 3, 0); // consolidation successful
  assert journal.hasEvents([
    #consolidated({ credited = 3; deducted = 8; fee = 5 }),
  ]);

  assert not handler.isFrozen();
};

do {
  let ledger = MockLedger.MockLedger(DEBUG, "");
  // fresh handler
  let (handler, journal, state) = Util.createHandler(ledger, false);
  // stage a response
  let i = ledger.fee_.stage(?5);
  // trigger call
  let fut1 = async { await* handler.fetchFee() };
  // wait for call to arrive
  await* ledger.fee_.wait(i, #called);
  // trigger second call
  assert (await* handler.fetchFee()) == null;
  // release response
  ledger.fee_.release(i);
  assert (await fut1) == ?5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0; delta = 0 }),
  ]);

  // stage a response and release it immediately
  ignore ledger.balance_.stage_unlocked(?20);
  assert (await* handler.notify(user1)) == ?(20, 15); // (deposit, credit)
  assert journal.hasEvents([
    #newDeposit({ creditInc = 15; depositInc = 20; ledgerFee = 5; surcharge = 0 }),
  ]);
  assert state() == (20, 0, 1);
  ignore ledger.transfer_.stage_unlocked(null); // error response
  await* handler.trigger(1);
  assert journal.hasEvents([]);
  assert state() == (20, 0, 1);
  ignore ledger.transfer_.stage_unlocked(?(#Ok 0));
  await* handler.trigger(1);
  assert journal.hasEvents([
    #consolidated({ credited = 15; deducted = 20; fee = 5 }),
  ]);
  assert state() == (0, 15, 0);

  assert not handler.isFrozen();
};

// Multiple consolidations trigger
do {
  let ledger = MockLedger.MockLedger(DEBUG, "Multiple consolidations trigger");
  // fresh handler
  let (handler, journal, state) = Util.createHandler(ledger, false);

  // update fee first time
  ignore ledger.fee_.stage_unlocked(?5);
  ignore await* handler.fetchFee();
  assert handler.fee(#deposit) == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0; delta = 0 }),
  ]);

  // user1 notify with balance > fee
  ignore ledger.balance_.stage_unlocked(?6);
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state() == (6, 0, 1);
  assert journal.hasEvents([
    #newDeposit { creditInc = 1; depositInc = 6; ledgerFee = 5; surcharge = 0 },
  ]);

  // user2 notify with balance > fee
  ignore ledger.balance_.stage_unlocked(?10);
  assert (await* handler.notify(user2)) == ?(10, 5);
  assert state() == (16, 0, 2);
  assert journal.hasEvents([
    #newDeposit { creditInc = 5; depositInc = 10; ledgerFee = 5; surcharge = 0 },
  ]);

  // trigger only 1 consolidation (the maximum one)
  do {
    let i = ledger.transfer_.stage_unlocked(?(#Ok 0));
    await* handler.trigger(1);
    assert ledger.transfer_.state(i) == #responded;
    assert state() == (6, 5, 1); // user2 funds consolidated
    assert journal.hasEvents([
      #consolidated({ credited = 5; deducted = 10; fee = 5 }),
    ]);
  };

  // user2 notify again
  ignore ledger.balance_.stage_unlocked(?10);
  assert (await* handler.notify(user2)) == ?(10, 5);
  assert state() == (16, 5, 2);
  assert journal.hasEvents([
    #newDeposit { creditInc = 5; depositInc = 10; ledgerFee = 5; surcharge = 0 },
  ]);

  // trigger consolidation of all the deposits
  // n >= deposit_number
  do {
    let i = ledger.transfer_.stage_unlocked(?(#Ok 0));
    let j = ledger.transfer_.stage_unlocked(?(#Ok 0));
    await* handler.trigger(10);
    assert (ledger.transfer_.state(i), ledger.transfer_.state(j)) == (#responded, #responded);
    assert state() == (0, 11, 0); // all deposits consolidated
    assert journal.hasEvents([
      #consolidated({ credited = 5; deducted = 10; fee = 5 }),
      #consolidated({ credited = 1; deducted = 6; fee = 5 }),
    ]);
  };

  // user1 notify again
  ignore ledger.balance_.stage_unlocked(?6);
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state() == (6, 11, 1);
  assert journal.hasEvents([
    #newDeposit { creditInc = 1; depositInc = 6; ledgerFee = 5; surcharge = 0 },
  ]);

  // user2 notify again
  ignore ledger.balance_.stage_unlocked(?10);
  assert (await* handler.notify(user2)) == ?(10, 5);
  assert state() == (16, 11, 2);
  assert journal.hasEvents([
    #newDeposit { creditInc = 5; depositInc = 10; ledgerFee = 5; surcharge = 0 },
  ]);

  // user3 notify with balance > fee
  ignore ledger.balance_.stage_unlocked(?8);
  assert (await* handler.notify(user3)) == ?(8, 3);
  assert state() == (24, 11, 3);
  assert journal.hasEvents([
    #newDeposit { creditInc = 3; depositInc = 8; ledgerFee = 5; surcharge = 0 },
  ]);

  // trigger consolidation of all the deposits (n >= deposit_number)
  // with error calling the ledger on the 2nd deposit
  // so the consolidation loop must be stopped after attempting to consolidate the 2nd deposit
  do {
    let i = ledger.transfer_.stage_unlocked(?(#Ok 0));
    let j = ledger.transfer_.stage_unlocked(null);
    let k = ledger.transfer_.stage_unlocked(?(#Ok 0));
    await* handler.trigger(10);
    assert ((ledger.transfer_.state(i), ledger.transfer_.state(j), ledger.transfer_.state(k))) == (#responded, #responded, #staged);
    assert state() == (14, 16, 2); // only user2 deposit consolidated
    assert journal.hasEvents([
      #consolidated({ credited = 5; deducted = 10; fee = 5 }),
    ]);
  };

  assert not handler.isFrozen();
};

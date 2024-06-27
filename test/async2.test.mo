import Principal "mo:base/Principal";
import { print } "mo:base/Debug";

import TokenHandler "../src";
import ICRC1 "../src/ICRC1";
import Mock "mock";
import TestJournal "test_journal";

let ledger = object {
  public let fee_ = Mock.Method<Nat>();
  public let balance_ = Mock.Method<Nat>();
  public let transfer_ = Mock.Method<ICRC1.TransferResult>();
  public let transfer_from_ = Mock.Method<ICRC1.TransferFromResult>();
  public shared func fee() : async Nat {
    let r = fee_.pop();
    await* r.run();
    r.response();
  };
  public shared func balance_of(_ : ICRC1.Account) : async Nat {
    let r = balance_.pop();
    await* r.run();
    r.response();
  };
  public shared func transfer(_ : ICRC1.TransferArgs) : async ICRC1.TransferResult {
    let r = transfer_.pop();
    await* r.run();
    r.response();
  };
  public shared func transfer_from(_ : ICRC1.TransferFromArgs) : async ICRC1.TransferFromResult {
    let r = transfer_from_.pop();
    await* r.run();
    r.response();
  };
  public func isEmpty() : Bool {
    fee_.isEmpty() and balance_.isEmpty() and transfer_.isEmpty();
  };
};
let anon_p = Principal.fromBlob("");
let user1 = Principal.fromBlob("1");
let user2 = Principal.fromBlob("2");
let user3 = Principal.fromBlob("3");

func state(handler : TokenHandler.TokenHandler) : (Nat, Nat, Nat) {
  let s = handler.state();
  (
    s.balance.deposited,
    s.balance.consolidated,
    s.users.queued,
  );
};

func createHandler() : (TokenHandler.TokenHandler, TestJournal.TestJournal) {
  TestJournal.TestJournal()
  |> (
    TokenHandler.TokenHandler({
      ledgerApi = ledger;
      ownPrincipal = anon_p;
      initialFee = 0;
      triggerOnNotifications = false;
      log = _.log;
    }),
    _,
  );
};

module Debug {
  public func state(handler : TokenHandler.TokenHandler) {
    print(
      debug_show handler.state()
    );
  };
};

do {
  print("new test: change fee plus notify");
  // fresh handler
  let (handler, journal) = createHandler();
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
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // stage a response and release it immediately
  ledger.balance_.stage(?20).0 ();
  assert (await* handler.notify(user1)) == ?(20, 15); // (deposit, credit)
  assert journal.hasEvents([
    #issued(+15),
    #newDeposit(20),
  ]);
  assert state(handler) == (20, 0, 1);
  ledger.transfer_.stage(null).0 (); // error response
  await* handler.trigger(1);
  assert journal.hasEvents([
    #consolidationError(#CallIcrc1LedgerError),
    #issued(-15),
    #issued(+15),
  ]);
  assert state(handler) == (20, 0, 1);
  ledger.transfer_.stage(?(#Ok 0)).0 ();
  await* handler.trigger(1);
  assert journal.hasEvents([
    #consolidated({ credited = 15; deducted = 20 })
  ]);
  assert state(handler) == (0, 15, 0);
};

do {
  print("new test: withdrawal error");
  // make sure no staged responses are left from previous tests
  assert ledger.isEmpty();
  // fresh handler
  let (handler, journal) = createHandler();
  // giver user1 credit and put funds into the consolidated balance
  ledger.balance_.stage(?20).0 ();
  ledger.transfer_.stage(?(#Ok 0)).0 ();
  assert (await* handler.notify(user1)) == ?(20, 20); // (deposit, credit)
  assert journal.hasEvents([
    #issued(+20),
    #newDeposit(20),
  ]);
  await* handler.trigger(1);
  assert journal.hasEvents([
    #consolidated({ credited = 20; deducted = 20 })
  ]);
  // stage a response
  let (release, state) = ledger.transfer_.stage(?(#Err(#BadFee { expected_fee = 10 })));
  assert handler.fee(#deposit) == 0;
  // transfer 20 credits from user to pool
  assert handler.debitUser(user1, 20);
  assert journal.hasEvents([
    #debited(20)
  ]);
  // start withdrawal and move it to background task
  var has_started = false;
  let fut = async {
    has_started := true;
    await* handler.withdrawFromPool({ owner = user1; subaccount = null }, 10);
  };
  // we wait for background task to start
  // this can also be done with a single await async {} statement
  // the loop seems more robust but is normally not necessary
  while (not has_started) { await async {} };
  // now the withdraw call has executed until its first commit point
  // let's verify
  assert handler.state().flow.withdrawn == 10;
  // also the call to the mock ledger method has been made
  assert state() == #running;
  // now everything is halted until we release the response
  release();
  // we wait for loop to finish until the response is ready
  while (state() == #running) { await async {} };
  assert state() == #ready;
  // the ledger has an async interface (not async*)
  // hence one more wait is required before the caller resumes the continuation
  // this cannot be done in a different way
  // there is nothing specific that we can wait for in a while loop
  await async {};
  // now the continuation in the withdraw call has executed
  // let's verify
  assert handler.fee(#deposit) == 10; // #BadFee has been processed
  // because of the #TooLowQuantity error there is no further commit point
  // the continuation runs to the end of the withdraw function
  // let's verify
  assert handler.state().flow.withdrawn == 0;
  assert journal.hasEvents([
    #burned(10),
    #feeUpdated({ new = 10; old = 0 }),
    #depositMinimumUpdated({ new = 11; old = 1 }),
    #withdrawalMinimumUpdated({ new = 11; old = 1 }),
    #depositFeeUpdated({ new = 10; old = 0 }),
    #withdrawalFeeUpdated({ new = 10; old = 0 }),
    #withdrawalError(#TooLowQuantity),
    #issued(+10),
  ]);
  // we do not have to await fut anymore, but we can:
  assert (await fut) == #err(#TooLowQuantity);
};

do {
  print("new test: successful withdrawal");
  // make sure no staged responses are left from previous tests
  assert ledger.isEmpty();
  // fresh handler
  let (handler, journal) = createHandler();
  // give user1 20 credits
  handler.issue_(#user user1, 20);
  assert journal.hasEvents([#issued(20)]);
  // stage two responses
  let (release, state) = ledger.transfer_.stage(?(#Err(#BadFee { expected_fee = 10 })));
  let (release2, state2) = ledger.transfer_.stage(?(#Ok 0));
  assert handler.fee(#deposit) == 0;
  // transfer 20 credits from user to pool
  assert handler.debitUser(user1, 20);
  assert journal.hasEvents([#debited(20)]);
  // start withdrawal and move it to background task
  let fut = async {
    await* handler.withdrawFromPool({ owner = user1; subaccount = null }, 11);
  };
  // we wait for the response to be processed
  release();
  while (state() != #ready) { await async {} };
  await async {};
  // now the continuation in the withdraw call has executed to the second commit point
  // let's verify
  assert handler.fee(#deposit) == 10; // #BadFee has been processed
  assert journal.hasEvents([
    #burned(11),
    #feeUpdated({ new = 10; old = 0 }),
    #depositMinimumUpdated({ new = 11; old = 1 }),
    #withdrawalMinimumUpdated({ new = 11; old = 1 }),
    #depositFeeUpdated({ new = 10; old = 0 }),
    #withdrawalFeeUpdated({ new = 10; old = 0 }),
  ]);
  // now everything is halted until we release the second response
  // we wait for the second response to be processed
  release2();
  while (state2() != #ready) { await async {} };
  await async {};
  // now the second contination has executed and withdraw has run to the end
  // let's verify
  assert journal.hasEvents([
    #withdraw({ amount = 11; to = { owner = user1; subaccount = null } })
  ]);
  // we do not have to await fut anymore, but we can:
  assert (await fut) == #ok(0, 1);
};

do {
  print("new test: multiple consolidations trigger");

  let (handler, journal) = createHandler();

  // update fee first time
  ledger.fee_.stage(?5).0 ();
  ignore await* handler.fetchFee();
  assert handler.fee(#deposit) == 5;
  assert journal.hasEvents([
    #feeUpdated({ new = 5; old = 0 }),
    #depositMinimumUpdated({ new = 6; old = 1 }),
    #withdrawalMinimumUpdated({ new = 6; old = 1 }),
    #depositFeeUpdated({ new = 5; old = 0 }),
    #withdrawalFeeUpdated({ new = 5; old = 0 }),
  ]);

  // user1 notify with balance > fee
  ledger.balance_.stage(?6).0 ();
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state(handler) == (6, 0, 1);
  assert journal.hasEvents([
    #issued(+1),
    #newDeposit(6),
  ]);

  // user2 notify with balance > fee
  ledger.balance_.stage(?10).0 ();
  assert (await* handler.notify(user2)) == ?(10, 5);
  assert state(handler) == (16, 0, 2);
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
    assert state(handler) == (10, 1, 1); // user1 funds consolidated
    assert journal.hasEvents([
      #consolidated({ credited = 1; deducted = 6 })
    ]);
  };

  // user1 notify again
  ledger.balance_.stage(?6).0 ();
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state(handler) == (16, 1, 2);
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
    assert state(handler) == (0, 7, 0); // all deposits consolidated
    assert journal.hasEvents([
      #consolidated({ credited = 1; deducted = 6 }),
      #consolidated({ credited = 5; deducted = 10 }),
    ]);
  };

  // user1 notify again
  ledger.balance_.stage(?6).0 ();
  assert (await* handler.notify(user1)) == ?(6, 1);
  assert state(handler) == (6, 7, 1);
  assert journal.hasEvents([
    #issued(+1),
    #newDeposit(6),
  ]);

  // user2 notify again
  ledger.balance_.stage(?10).0 ();
  assert (await* handler.notify(user2)) == ?(10, 5);
  assert state(handler) == (16, 7, 2);
  assert journal.hasEvents([
    #issued(+5),
    #newDeposit(10),
  ]);

  // user3 notify with balance > fee
  ledger.balance_.stage(?8).0 ();
  assert (await* handler.notify(user3)) == ?(8, 3);
  assert state(handler) == (24, 7, 3);
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
    assert state(handler) == (18, 8, 2); // only user1 deposit consolidated
    assert journal.hasEvents([
      #consolidated({ credited = 1; deducted = 6 }),
      #consolidationError(#CallIcrc1LedgerError),
      #issued(-5),
      #issued(+5),
    ]);
  };

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

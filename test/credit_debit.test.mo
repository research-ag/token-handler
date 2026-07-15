import Principal "mo:core/Principal";

import TokenHandler "../src";
import MockLedger "util/mock_ledger";
import Util "util/common";

// Tests for creditUser / debitUser boundary conditions and pool accounting.

let DEBUG = false;
let user1 = Principal.fromBlob("1");
let user2 = Principal.fromBlob("2");
let unknown = Principal.fromBlob("42");
let user1_account = { owner = user1; subaccount = null };

do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "credit_debit");
  let (handler, ctx, journal, _) = Util.createHandler(mock_ledger, false);

  // ledger fee stays 0, surcharge stays 0

  // Credit for an unknown user is 0.
  assert handler.userCredit(unknown) == 0;
  assert handler.poolCredit() == 0;
  assert handler.handlerCredit() == 0;

  // Fund user1 credit via allowance (no consolidation needed).
  ignore mock_ledger.transfer_from_.stage_unlocked(?#Ok 1);
  assert (await* TokenHandler.depositFromAllowance(handler, user1, user1_account, 100, null, ctx)) == #ok(100, 1);
  assert handler.userCredit(user1) == 100;
  assert journal.hasEvents([
    #allowanceDrawn { amount = 100; credited = 100; surcharge = 0 },
  ]);

  // debitUser: credit < amount -> no change.
  assert handler.debitUser(user1, 101, ctx) == false;
  assert handler.userCredit(user1) == 100;
  assert handler.poolCredit() == 0;
  assert journal.hasEvents([]);

  // debitUser: amount < credit -> moves credit to the pool.
  assert handler.debitUser(user1, 50, ctx) == true;
  assert handler.userCredit(user1) == 50;
  assert handler.poolCredit() == 50;
  assert journal.hasEvents([#debited(50)]);

  // debitUser: amount == credit (boundary) -> succeeds, credit becomes 0.
  assert handler.debitUser(user1, 50, ctx) == true;
  assert handler.userCredit(user1) == 0;
  assert handler.poolCredit() == 100;
  assert journal.hasEvents([#debited(50)]);

  // creditUser: amount > pool -> no change.
  assert handler.creditUser(user1, 101, ctx) == false;
  assert handler.userCredit(user1) == 0;
  assert handler.poolCredit() == 100;
  assert journal.hasEvents([]);

  // creditUser: amount == pool (boundary) -> succeeds, pool becomes 0.
  assert handler.creditUser(user2, 100, ctx) == true;
  assert handler.userCredit(user2) == 100;
  assert handler.poolCredit() == 0;
  assert journal.hasEvents([#credited(100)]);

  // creditUser with empty pool -> no change.
  assert handler.creditUser(user1, 1, ctx) == false;
  assert journal.hasEvents([]);

  assert not handler.isFrozen();
};

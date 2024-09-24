import Principal "mo:base/Principal";

import MockLedger "util/mock_ledger";
import Util "util/common";

let DEBUG = true;
let user1 = Principal.fromBlob("1");
let user2 = Principal.fromBlob("2");
let user1_account = { owner = user1; subaccount = null };
let user2_account = { owner = user2; subaccount = null };

do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "");
  let (handler, journal, state) = Util.createHandler(mock_ledger, false);

  // update fee first time
  ignore mock_ledger.fee_.stage_unlocked(?3);
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

  // deposit via allowance < amount + fee
  ignore mock_ledger.transfer_from_.stage_unlocked(?#Err(#InsufficientAllowance({ allowance = 8 })));
  assert (await* handler.depositFromAllowance(user1, user1_account, 4, null)) == #err(#InsufficientAllowance({ allowance = 8 }));
  assert state() == (0, 0, 0);
  assert journal.hasEvents([
    #allowanceError(#InsufficientAllowance({ allowance = 8 }))
  ]);

  // deposit via allowance >= amount + fee
  ignore mock_ledger.transfer_from_.stage_unlocked(?#Ok 42);
  assert (await* handler.depositFromAllowance(user1, user1_account, 3, null)) == #ok(3, 42);
  assert handler.userCredit(user1) == 3;
  assert state() == (0, 5, 0);
  assert journal.hasEvents([
    #allowanceDrawn({ amount = 3 }),
    #issued(+3), // credit to user
    #issued(+2), // credit to pool
  ]);

  // deposit from allowance >= amount
  // caller principal != account owner
  ignore mock_ledger.transfer_from_.stage_unlocked(?#Ok 42);
  assert (await* handler.depositFromAllowance(user1, user2_account, 7, null)) == #ok(7, 42);
  assert handler.userCredit(user1) == 10;
  assert state() == (0, 14, 0);
  assert journal.hasEvents([
    #allowanceDrawn({ amount = 7 }),
    #issued(+7), // credit to user
    #issued(+2), // credit to pool
  ]);

  // deposit via allowance with fee expectation
  // expected_fee != ledger_fee
  // not staging a response to assert that no call is happening
  // allowance fee = 5
  assert (await* handler.depositFromAllowance(user1, user1_account, 2, ?100)) == #err(#BadFee({ expected_fee = 5 }));
  assert handler.userCredit(user1) == 10; // not changed
  assert state() == (0, 14, 0); // not changed
  assert journal.hasEvents([
    #allowanceError(#BadFee({ expected_fee = 5 }))
  ]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};
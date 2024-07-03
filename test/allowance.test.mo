import Principal "mo:base/Principal";

import Util "util/common";
import MockLedger "util/mock_ledger";

let user1 = Principal.fromBlob("1");
let user2 = Principal.fromBlob("2");
let user1_account = { owner = user1; subaccount = null };
let user2_account = { owner = user2; subaccount = null };

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

  // deposit via allowance < amount + ledger_fee
  await mock_ledger.set_transfer_from_res([#Err(#InsufficientAllowance({ allowance = 8 }))]);
  assert (await* handler.depositFromAllowance(user1, user1_account, 6, null)) == #err(#InsufficientAllowance({ allowance = 8 }));
  assert state() == (0, 0, 0);
  assert journal.hasEvents([
    #allowanceError(#InsufficientAllowance({ allowance = 8 }))
  ]);

  // deposit via allowance >= amount + ledger_fee
  await mock_ledger.set_transfer_from_res([#Ok 42]);
  assert (await* handler.depositFromAllowance(user1, user1_account, 5, null)) == #ok(3, 42);
  assert handler.userCredit(user1) == 3;
  assert state() == (0, 5, 0);
  assert journal.hasEvents([
    #allowanceDrawn({ credited = 3 }),
    #issued(+3), // credit to user
    #issued(+2), // credit to pool
  ]);

  // deposit from allowance >= amount
  // caller principal != account owner
  await mock_ledger.set_transfer_from_res([#Ok 42]);
  assert (await* handler.depositFromAllowance(user1, user2_account, 9, null)) == #ok(9, 42);
  assert handler.userCredit(user1) == 10;
  assert state() == (0, 14, 0);
  assert journal.hasEvents([
    #allowanceDrawn({ credited = 7 }),
    #issued(+7), // credit to user
    #issued(+2), // credit to pool
  ]);

  // deposit via allowance <= fee
  await mock_ledger.set_transfer_from_res([#Ok 42]); // should be not called
  var transfer_from_count = await mock_ledger.transfer_from_count();
  // allowance fee = 2
  assert (await* handler.depositFromAllowance(user1, user1_account, 2, null)) == #err(#TooLowQuantity);
  assert handler.userCredit(user1) == 10; // not changed
  assert state() == (0, 14, 0); // not changed
  assert transfer_from_count == (await mock_ledger.transfer_from_count());
  assert journal.hasEvents([
    #allowanceError(#TooLowQuantity)
  ]);

  // deposit via allowance with fee expectation
  // expected_fee != ledger_fee
  await mock_ledger.set_transfer_from_res([#Ok 42]); // should be not called
  var transfer_from_count_2 = await mock_ledger.transfer_from_count();
  // allowance fee = 2
  assert (await* handler.depositFromAllowance(user1, user1_account, 2, ?100)) == #err(#BadFee({ expected_fee = 2 }));
  assert handler.userCredit(user1) == 3; // not changed
  assert state() == (0, 5, 0); // not changed
  assert transfer_from_count_2 == (await mock_ledger.transfer_from_count());
  assert journal.hasEvents([
    #allowanceError(#BadFee({ expected_fee = 2 }))
  ]);

  handler.assertIntegrity();
  assert not handler.isFrozen();
};

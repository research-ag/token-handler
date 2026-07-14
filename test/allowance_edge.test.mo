import Principal "mo:core/Principal";

import TokenHandler "../src";
import MockLedger "util/mock_ledger";
import Util "util/common";

// Additional edge cases for depositFromAllowance.

let DEBUG = false;
let user1 = Principal.fromBlob("1");
let user1_account = { owner = user1; subaccount = null };

do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "allowance_edge");
  let (handler, ctx, journal, _) = Util.createHandler(mock_ledger, false);

  ignore mock_ledger.fee_.stage_unlocked(?2);
  ignore await* TokenHandler.fetchFee(handler, ctx);
  handler.setSurcharge(1, ctx);
  assert journal.hasEvents([
    #feeUpdated({ new = 2; old = 0; delta = 0 }),
    #surchargeUpdated({ new = 1; old = 0 }),
  ]);
  assert handler.fee(#allowance) == 3;

  // Case 1: correct expectedFee is accepted.
  ignore mock_ledger.transfer_from_.stage_unlocked(? #Ok 1);
  assert (await* TokenHandler.depositFromAllowance(handler, user1, user1_account, 10, ?3, ctx)) == #ok(10, 1);
  assert handler.userCredit(user1) == 10;
  assert handler.handlerCredit() == 1; // surcharge accumulated in the pool
  assert journal.hasEvents([
    #allowanceDrawn({ amount = 11; credited = 10; surcharge = 1 }),
  ]);

  // Case 2: the ledger reports a BadFee; the tracked fee is updated and the
  // call fails without crediting the user.
  ignore mock_ledger.transfer_from_.stage_unlocked(? #Err(#BadFee({ expected_fee = 7 })));
  assert (await* TokenHandler.depositFromAllowance(handler, user1, user1_account, 5, null, ctx)) == #err(#BadFee({ expected_fee = 7 }));
  assert handler.ledgerFee() == 7; // fee auto-updated from the ledger response
  assert handler.userCredit(user1) == 10; // unchanged
  assert journal.hasEvents([
    #feeUpdated({ new = 7; old = 2; delta = 0 }),
  ]);

  // Case 3: a genuine transfer error is propagated without state change.
  ignore mock_ledger.transfer_from_.stage_unlocked(? #Err(#InsufficientFunds({ balance = 1 })));
  assert (await* TokenHandler.depositFromAllowance(handler, user1, user1_account, 5, null, ctx)) == #err(#InsufficientFunds({ balance = 1 }));
  assert handler.userCredit(user1) == 10; // unchanged
  assert journal.hasEvents([]);

  assert not handler.isFrozen(ctx);
};

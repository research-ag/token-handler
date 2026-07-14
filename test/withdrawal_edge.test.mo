import Principal "mo:core/Principal";

import TokenHandler "../src";
import MockLedger "util/mock_ledger";
import Util "util/common";

// Edge cases for withdrawals: refund paths and expectedFee mismatches.

let DEBUG = false;
let user1 = Principal.fromBlob("1");
let account = { owner = Principal.fromBlob("o"); subaccount = null };

do {
  let mock_ledger = MockLedger.MockLedger(DEBUG, "withdrawal_edge");
  let (handler, ctx, journal, _) = Util.createHandler(mock_ledger, false);

  ignore mock_ledger.fee_.stage_unlocked(?1);
  ignore await* TokenHandler.fetchFee(handler, ctx);
  handler.setSurcharge(2);
  assert journal.hasEvents([
    #feeUpdated({ new = 1; old = 0; delta = 0 }),
    #surchargeUpdated({ new = 2; old = 0 }),
  ]);

  // Get consolidated credit for user1.
  ignore mock_ledger.balance_.stage_unlocked(?20);
  assert (await* TokenHandler.notify(handler, user1, ctx)) == ?(20, 17);
  assert journal.hasEvents([
    #newDeposit({ creditInc = 17; depositInc = 20; ledgerFee = 1; surcharge = 2 }),
  ]);
  ignore mock_ledger.transfer_.stage_unlocked(? #Ok 0);
  await* TokenHandler.trigger(handler, 1, ctx);
  assert journal.hasEvents([
    #consolidated({ credited = 19; deducted = 20; fee = 1 }),
  ]);
  assert handler.userCredit(user1) == 17;

  // Case C: generic transfer error on withdrawFromCredit -> credit refunded.
  ignore mock_ledger.transfer_.stage_unlocked(null); // triggers CallIcrc1LedgerError
  assert (await* TokenHandler.withdrawFromCredit(handler, user1, account, 10, null, ctx)) == #err(#CallIcrc1LedgerError);
  assert handler.userCredit(user1) == 17; // refunded
  assert journal.hasEvents([
    #locked(10),
    #locked(-10),
  ]);

  // Case D: expectedFee mismatch on withdrawFromCredit -> no ledger call.
  assert (await* TokenHandler.withdrawFromCredit(handler, user1, account, 10, ?100, ctx)) == #err(#BadFee({ expected_fee = 3 }));
  assert handler.userCredit(user1) == 17; // unchanged
  assert journal.hasEvents([]);

  // Move all the credit into the pool to test pool withdrawals.
  assert handler.debitUser(user1, 17) == true;
  assert handler.poolCredit() == 17;
  assert journal.hasEvents([#debited(17)]);

  // Case A: expectedFee mismatch on withdrawFromPool (fee = ledgerFee only).
  assert (await* TokenHandler.withdrawFromPool(handler, account, 10, ?5, ctx)) == #err(#BadFee({ expected_fee = 1 }));
  assert handler.poolCredit() == 17; // unchanged
  assert journal.hasEvents([]);

  // Case B: BadFee from ledger on withdrawFromPool -> pool refunded, fee updated.
  ignore mock_ledger.transfer_.stage_unlocked(? #Err(#BadFee({ expected_fee = 3 })));
  assert (await* TokenHandler.withdrawFromPool(handler, account, 10, null, ctx)) == #err(#BadFee({ expected_fee = 3 }));
  assert handler.poolCredit() == 17; // refunded
  assert handler.ledgerFee() == 3; // fee auto-updated
  assert journal.hasEvents([
    #locked(10),
    #feeUpdated({ new = 3; old = 1; delta = 0 }),
    #locked(-10),
  ]);

  // Case E: successful withdrawFromPool after the fee change.
  ignore mock_ledger.transfer_.stage_unlocked(? #Ok 42);
  assert (await* TokenHandler.withdrawFromPool(handler, account, 10, null, ctx)) == #ok(42, 7);
  assert handler.poolCredit() == 7;
  assert journal.hasEvents([
    #locked(10),
    #withdraw({ amount = 10; withdrawn = 10; surcharge = 0; to = account }),
  ]);

  assert not handler.isFrozen();
};

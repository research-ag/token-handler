import TestJournal "test_journal";
import Principal "mo:base/Principal";

do {
  let anon_p = Principal.fromBlob("");
  let journal = TestJournal.TestJournal();

  // initial state
  assert journal.hasEvents([]);
  assert journal.size() == 0;

  // add some logs
  journal.log(anon_p, #newDeposit { creditInc = 15; depositInc = 20; ledgerFee = 3; surcharge = 2 });
  journal.log(anon_p, #credited(1));
  assert journal.hasEvents([#newDeposit { creditInc = 15; depositInc = 20; ledgerFee = 3; surcharge = 2 }, #credited(1)]);
  assert journal.size() == 2;

  // check with no new events
  assert journal.hasEvents([]);
  assert journal.hasEvents([#debited 0]) == false;
  assert journal.hasEvents([]);
  assert journal.size() == 2;
};
